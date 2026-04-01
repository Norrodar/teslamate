defmodule TeslaMate.Import.TeslaLogger do
  @moduledoc false

  use GenServer

  require Logger

  import Ecto.Query

  alias __MODULE__.{Status, MysqlReader, Mapper, Validator, Writer}
  alias TeslaMate.{Repo, Repair}
  alias TeslaMate.Log
  alias TeslaMate.Log.Car
  alias TeslaMate.Settings.CarSettings

  defstruct [
    :config,
    :mysql_conn,
    status: Status.initial(),
    car_mapping: %{},
    date_to_pos_id: %{}
  ]

  @name __MODULE__
  @topic "#{@name}/state"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def get_status, do: GenServer.call(@name, :get_status)
  def run(car_mapping \\ %{}, opts \\ []), do: GenServer.call(@name, {:run, car_mapping, opts}, :infinity)
  def preflight, do: GenServer.call(@name, :preflight, :infinity)
  def enabled?, do: is_pid(Process.whereis(@name))
  def subscribe, do: Phoenix.PubSub.subscribe(TeslaMate.PubSub, @topic)

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:preflight, _from, state) do
    if state.status.state in [:running, :preflight] do
      {:reply, {:error, :busy}, state}
    else
      send(self(), :run_preflight)
      {:reply, :ok, state}
    end
  end

  def handle_call({:run, car_mapping, opts}, _from, state) do
    if state.status.state in [:running, :preflight] do
      {:reply, {:error, :already_running}, state}
    else
      mode = Keyword.get(opts, :mode, :clean)
      state = %{state | car_mapping: car_mapping}
      state = update_status(state, fn s -> %{s | import_mode: mode} end)
      send(self(), :start_import)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:run_preflight, state) do
    parent = self()

    {:ok, pid} =
      Task.start_link(fn ->
        result_state = run_preflight_steps(state, parent)
        send(parent, {:preflight_done, result_state})
      end)

    Process.monitor(pid)
    {:noreply, %{state | status: %{state.status | state: :preflight}}}
  end

  def handle_info({:preflight_update, status}, state) do
    {:noreply, %{state | status: status}}
  end

  def handle_info({:preflight_done, result_state}, state) do
    # Only merge status and mysql_conn from task — preserve car_mapping, import_mode etc.
    {:noreply, %{state | status: result_state.status, mysql_conn: result_state.mysql_conn}}
  end

  def handle_info(:start_import, state) do
    parent = self()

    {:ok, pid} =
      Task.start_link(fn ->
        result_state = do_import(state)
        send(parent, {:import_done, result_state})
      end)

    Process.monitor(pid)
    {:noreply, state}
  end

  def handle_info({:import_done, result_state}, state) do
    # Merge back status and date_to_pos_id — preserve car_mapping etc.
    {:noreply, %{state | status: result_state.status, date_to_pos_id: result_state.date_to_pos_id}}
  end

  # Handle Task crash — reset state so GenServer doesn't get stuck
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("Import/preflight task crashed: #{inspect(reason)}")

    new_status =
      if state.status.state in [:running, :preflight] do
        %{state.status | state: {:error, "Task crashed: #{inspect(reason)}"}}
      else
        state.status
      end

    broadcast(new_status)
    {:noreply, %{state | status: new_status}}
  end

  ## Import Orchestration

  defp do_import(state) do
    # If preflight already ran (mysql_conn exists), skip connect+preflight
    case ensure_connected(state) do
      {:error, reason, state} ->
        update_status(state, &Status.set_state(&1, {:error, reason}))

      {:ok, state} ->
        state = update_status(state, &Status.set_state(&1, :running))

        case import_cars(state) do
          {:error, reason, state} ->
            update_status(state, &Status.set_state(&1, {:error, reason}))

          {:ok, state} ->
            case mode_precheck(state) do
              {:error, reason, state} ->
                update_status(state, &Status.set_state(&1, {:error, reason}))

              {:ok, state} ->
                state = import_all_car_data(state)

                if match?({:error, _}, state.status.state) do
                  state
                else
                  finalize(state)
                end
            end
        end
    end
  end

  defp ensure_connected(state) do
    if state.mysql_conn do
      {:ok, state}
    else
      state
      |> update_status(&Status.set_state(&1, :connecting))
      |> connect_mysql()
      |> case do
        {:error, reason, state} ->
          {:error, "MySQL connection failed: #{inspect(reason)}", state}

        {:ok, state} ->
          run_preflight_check(state)
      end
    end
  end

  defp run_preflight_steps(state, parent) do
    state = update_status(state, &Status.set_state(&1, :preflight))
    sync_preflight(parent, state)

    # Step 1: Connect to MySQL
    state = update_status(state, &Status.update_preflight_step(&1, :connecting, :running))
    sync_preflight(parent, state)

    case connect_mysql(state) do
      {:error, reason, state} ->
        detail = "MySQL connection failed: #{inspect(reason)}"
        state = update_status(state, &Status.update_preflight_step(&1, :connecting, {:error, detail}, detail))
        update_status(state, &Status.set_state(&1, {:error, detail}))

      {:ok, state} ->
        state = update_status(state, &Status.update_preflight_step(&1, :connecting, :complete))
        sync_preflight(parent, state)

        # Step 2: Read TeslaLogger data
        run_preflight_read_source(state, parent)
    end
  end

  defp run_preflight_read_source(state, parent) do
    state = update_status(state, &Status.update_preflight_step(&1, :reading_source, :running))
    sync_preflight(parent, state)

    case MysqlReader.preflight_check(state.mysql_conn) do
      {:ok, car_info} ->
        count = length(car_info)
        detail = "Found #{count} car(s)"
        Logger.info("Preflight: #{detail}")

        Enum.each(car_info, fn c ->
          if c["vin"] && c["vin"] != "" do
            Logger.info("  Car #{c["id"]}: VIN #{c["vin"]} (#{c["display_name"]})")
          else
            Logger.warning("  Car #{c["id"]}: No VIN found (#{c["display_name"]})")
          end
        end)

        state = update_status(state, &Status.update_preflight_step(&1, :reading_source, :complete, detail))
        state = update_status(state, fn s -> %{s | mysql_car_info: car_info} end)
        sync_preflight(parent, state)

        # Step 3: Check TeslaMate data
        run_preflight_check_target(state, parent)

      {:error, reason} ->
        Logger.error("Preflight read failed: #{reason}")
        state = update_status(state, &Status.update_preflight_step(&1, :reading_source, {:error, reason}, reason))
        update_status(state, &Status.set_state(&1, {:error, reason}))
    end
  end

  defp run_preflight_check_target(state, parent) do
    state = update_status(state, &Status.update_preflight_step(&1, :checking_target, :running))
    sync_preflight(parent, state)

    # For each car with a VIN, check if TeslaMate already has data
    {car_info_with_tm, any_has_data} =
      Enum.map_reduce(state.status.mysql_car_info, false, fn car_info, has_data_acc ->
        vin = car_info["vin"]

        try do
          case Writer.check_tm_data_for_vin(vin) do
            {:ok, nil} ->
              enriched = Map.merge(car_info, %{"tm_car_id" => nil, "tm_data_counts" => nil})
              {enriched, has_data_acc}

            {:ok, %{tm_car_id: tm_id, tm_data_counts: counts}} ->
              has_data = map_size(counts) > 0
              enriched = Map.merge(car_info, %{"tm_car_id" => tm_id, "tm_data_counts" => counts})
              {enriched, has_data_acc or has_data}
          end
        rescue
          e ->
            Logger.warning("Failed to check TM data for VIN #{inspect(vin)}: #{inspect(e)}")
            enriched = Map.merge(car_info, %{"tm_car_id" => nil, "tm_data_counts" => nil})
            {enriched, has_data_acc}
        end
      end)

    detail = if any_has_data, do: "Existing TeslaMate data found", else: "No existing data"

    state = update_status(state, fn s ->
      %{s | mysql_car_info: car_info_with_tm, tm_has_data: any_has_data}
    end)

    state = update_status(state, &Status.update_preflight_step(&1, :checking_target, :complete, detail))
    update_status(state, &Status.set_state(&1, :idle))
  end

  # Sends intermediate preflight state to GenServer so get_status() stays current
  defp sync_preflight(parent, state) do
    send(parent, {:preflight_update, state.status})
  end

  # Legacy preflight for ensure_connected path (import without prior preflight)
  defp run_preflight_check(state) do
    Logger.info("Running preflight check on TeslaLogger database...")

    case MysqlReader.preflight_check(state.mysql_conn) do
      {:ok, car_info} ->
        Logger.info("Preflight check passed — found #{length(car_info)} car(s)")
        state = update_status(state, fn s -> %{s | mysql_car_info: car_info} end)
        {:ok, state}

      {:error, reason} ->
        Logger.error("Preflight check failed: #{reason}")
        {:error, reason, state}
    end
  end

  defp mode_precheck(state) do
    mode = state.status.import_mode

    if mode == :clean do
      Enum.reduce_while(state.car_mapping, {:ok, state}, fn {_tl_id, car}, {:ok, s} ->
        case Writer.check_car_has_no_data(car.id) do
          :ok ->
            {:cont, {:ok, s}}

          {:error, {:data_exists, counts}} ->
            counts_str =
              counts
              |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
              |> Enum.join(", ")

            msg = "Car #{car.vin || car.id} already has data (#{counts_str}). Use a merge mode or empty the database first."
            Logger.error("Mode precheck failed: #{msg}")
            {:halt, {:error, msg, s}}
        end
      end)
    else
      {:ok, state}
    end
  end

  defp connect_mysql(state) do
    config = state.config

    case MysqlReader.connect(config) do
      {:ok, conn} ->
        Logger.info("Connected to TeslaLogger MySQL at #{config[:host]}:#{config[:port]}")
        {:ok, %{state | mysql_conn: conn}}

      {:error, reason} ->
        Logger.error("Failed to connect to TeslaLogger MySQL: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp import_cars(state) do
    conn = state.mysql_conn

    case MysqlReader.read_cars(conn) do
      {:ok, tl_cars} ->
        Logger.info("Found #{length(tl_cars)} car(s) in TeslaLogger")
        car_count = length(tl_cars)
        state = update_status(state, fn s -> %{s | car_count: car_count} end)
        state = update_status(state, &Status.start_step(&1, :cars, car_count))

        car_mapping =
          Enum.reduce_while(tl_cars, {:ok, %{}}, fn tl_car, {:ok, acc} ->
            tl_car_id = tl_car["id"]

            case create_or_find_car(tl_car, state.car_mapping) do
              {:ok, car} ->
                Logger.info("Mapped TeslaLogger car #{tl_car_id} -> TeslaMate car #{car.id} (#{car.name || car.vin})")
                {:cont, {:ok, Map.put(acc, tl_car_id, car)}}

              {:error, :vin_required} ->
                msg = "TeslaLogger car #{tl_car_id} (#{tl_car["display_name"]}) has no VIN. Please provide a VIN in the import form."
                Logger.error(msg)
                {:halt, {:error, msg}}

              {:error, reason} ->
                Logger.warning("Failed to create car for TeslaLogger car #{tl_car_id}: #{inspect(reason)}")
                {:cont, {:ok, acc}}
            end
          end)

        case car_mapping do
          {:ok, mapping} ->
            state = %{state | car_mapping: mapping}
            {:ok, update_status(state, &Status.complete_step(&1, :cars))}

          {:error, msg} ->
            {:error, msg, update_status(state, &Status.fail_step(&1, :cars, msg))}
        end

      {:error, reason} ->
        Logger.error("Failed to read cars: #{inspect(reason)}")
        {:error, inspect(reason), update_status(state, &Status.fail_step(&1, :cars, inspect(reason)))}
    end
  end

  defp import_all_car_data(state) do
    Enum.reduce(state.car_mapping, state, fn {tl_car_id, car}, state ->
      # Skip if a previous step already failed
      if match?({:error, _}, state.status.state) do
        state
      else
        Logger.info("Importing data for car #{car.id} (TeslaLogger ID: #{tl_car_id})")
        timezone = state.config[:timezone]

        # Mode C: Pre-delete all overlapping data in FK-safe order BEFORE importing
        case maybe_pre_delete_overlapping(state, tl_car_id, car.id, timezone) do
          {:error, reason, state} ->
            update_status(state, &Status.set_state(&1, {:error, "Pre-deletion failed: #{inspect(reason)}"}))

          {:ok, state} ->
            state
            |> import_positions(tl_car_id, car.id, timezone)
            |> import_drives(tl_car_id, car.id, timezone)
            |> import_charging_data(tl_car_id, car.id, timezone)
            |> import_states(tl_car_id, car.id, timezone)
            |> import_updates(tl_car_id, car.id, timezone)
        end
      end
    end)
  end

  defp maybe_pre_delete_overlapping(state, tl_car_id, car_id, timezone) do
    if state.status.import_mode != :merge_tl_priority do
      {:ok, state}
    else
      Logger.info("Mode C: Pre-deleting overlapping TeslaMate data for car #{car_id}...")
      conn = state.mysql_conn

      # Read TeslaLogger time ranges to compute what to delete
      with {:ok, pos_rows} <- MysqlReader.read_positions(conn, tl_car_id),
           {:ok, drive_rows} <- MysqlReader.read_drives(conn, tl_car_id),
           {:ok, cp_rows} <- MysqlReader.read_charging_sessions(conn, tl_car_id),
           {:ok, state_rows} <- MysqlReader.read_states(conn, tl_car_id) do

        # Compute overall time range from positions
        pos_dates = Enum.map(pos_rows, fn row -> Mapper.map_position(row, timezone).date end)
        pos_dates = Enum.reject(pos_dates, &is_nil/1)

        pos_range =
          if pos_dates != [] do
            min_d = Enum.min(pos_dates, DateTime)
            max_d = Enum.max(pos_dates, DateTime)
            [{min_d, max_d}]
          else
            []
          end

        # Compute ranges from drives, charging processes, states, updates
        drive_ranges = drive_rows |> Enum.map(fn r -> m = Mapper.map_drive(r, timezone); {m.start_date, m.end_date} end) |> Enum.reject(fn {s, _} -> is_nil(s) end)
        cp_ranges = cp_rows |> Enum.map(fn r -> m = Mapper.map_charging_process(r, timezone); {m.start_date, m.end_date} end) |> Enum.reject(fn {s, _} -> is_nil(s) end)
        state_ranges = state_rows |> Enum.map(fn r -> m = Mapper.map_state(r, timezone); {m.start_date, m.end_date} end) |> Enum.reject(fn {s, _} -> is_nil(s) end)

        # Note: updates are excluded from pre-deletion ranges because they have no end_date
        # (end_date is computed post-import). Including them would create unbounded {start, nil}
        # ranges that consolidate into infinite ranges and over-delete data.
        all_ranges = pos_range ++ drive_ranges ++ cp_ranges ++ state_ranges
        consolidated = Writer.consolidate_ranges(all_ranges)

        if consolidated != [] do
          Logger.info("Deleting overlapping TeslaMate data in #{length(consolidated)} time range(s)...")
          deleted = Writer.delete_overlapping_data(car_id, consolidated)
          Logger.info("Pre-deletion complete: #{inspect(deleted)}")
        end

        {:ok, state}
      else
        {:error, reason} ->
          Logger.error("Failed to compute TeslaLogger time ranges for pre-deletion: #{inspect(reason)}")
          {:error, reason, state}
      end
    end
  end

  defp import_positions(%{status: %{state: {:error, _}}} = state, _, _, _), do: state
  defp import_positions(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    with {:ok, total} <- MysqlReader.count_positions(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :positions, total)),
         state = update_status(state, &Status.set_phase(&1, :positions, :reading)),
         {:ok, rows} <- MysqlReader.read_positions(conn, tl_car_id) do

      state = update_status(state, &Status.set_phase(&1, :positions, :mapping))

      {mapped, _count} =
        Enum.map_reduce(rows, 0, fn row, count ->
          result = Mapper.map_position(row, timezone)
          new_count = count + 1

          if rem(new_count, 50_000) == 0 do
            broadcast(update_status(state, &Status.update_step_progress(&1, :positions, new_count)).status)
          end

          {result, new_count}
        end)

      # Merge TPMS data if available
      mapped =
        case MysqlReader.read_tpms(conn, tl_car_id) do
          {:ok, tpms_rows} when tpms_rows != [] ->
            Logger.info("Merging #{length(tpms_rows)} TPMS readings into positions")
            Mapper.merge_tpms(mapped, tpms_rows)

          _ ->
            mapped
        end

      state = update_status(state, &Status.set_phase(&1, :positions, :validating))

      {valid, errors} = Validator.validate_positions(mapped)
      warnings = Validator.format_warnings(errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      # Mode B: filter out positions that already exist in TeslaMate
      {valid, state} =
        if state.status.import_mode == :merge_tm_priority do
          state = update_status(state, &Status.set_phase(&1, :positions, :filtering))
          existing_set = Writer.load_existing_position_dates(car_id)

          filtered = Enum.reject(valid, fn pos ->
            MapSet.member?(existing_set, DateTime.to_unix(pos.date, :second))
          end)

          {filtered, state}
        else
          {valid, state}
        end

      state = update_status(state, &Status.set_phase(&1, :positions, :inserting))

      progress_fn = fn imported, _total ->
        broadcast(update_status(state, &Status.update_step_progress(&1, :positions, imported)).status)
      end

      case Writer.insert_positions(car_id, valid, progress_fn) do
        {:ok, new_date_map} ->
          state = %{state | date_to_pos_id: Map.merge(state.date_to_pos_id, new_date_map)}
          update_status(state, &Status.complete_step(&1, :positions))

        {:error, reason} ->
          Logger.error("Position insert failed: #{inspect(reason)}")
          update_status(state, &Status.fail_step(&1, :positions, inspect(reason)))
      end
    else
      {:error, reason} ->
        Logger.error("Failed to import positions: #{inspect(reason)}")
        update_status(state, &Status.fail_step(&1, :positions, inspect(reason)))
    end
  end

  defp import_drives(%{status: %{state: {:error, _}}} = state, _, _, _), do: state
  defp import_drives(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    with {:ok, total} <- MysqlReader.count_drives(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :drives, total)),
         state = update_status(state, &Status.set_phase(&1, :drives, :reading)),
         {:ok, rows} <- MysqlReader.read_drives(conn, tl_car_id) do

      state = update_status(state, &Status.set_phase(&1, :drives, :mapping))

      sorted_pos_array =
        Writer.build_sorted_array(state.date_to_pos_id, fn {dt, _} -> dt end, fn {dt, _} -> dt end)

      rows = filter_zero_duration(rows, "drives")

      {mapped, _count} =
        Enum.map_reduce(rows, 0, fn row, count ->
          drive_attrs = Mapper.map_drive(row, timezone)

          # Enrich with position data
          drive_positions =
            find_positions_in_range(
              sorted_pos_array,
              drive_attrs.start_date,
              drive_attrs.end_date
            )

          pos_attrs = get_position_attrs_for_dates(drive_positions, state.date_to_pos_id)
          enriched = Mapper.enrich_drive(drive_attrs, pos_attrs)

          new_count = count + 1

          if rem(new_count, 500) == 0 do
            broadcast(update_status(state, &Status.update_step_progress(&1, :drives, new_count)).status)
          end

          {enriched, new_count}
        end)

      state = update_status(state, &Status.set_phase(&1, :drives, :validating))

      {valid, errors} = Validator.validate_drives(mapped)
      warnings = Validator.format_warnings(errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      {valid, state} = maybe_filter_overlapping(state, :drives, :drives, car_id, valid)

      state = update_status(state, &Status.set_phase(&1, :drives, :inserting))

      drive_progress = fn inserted, _total ->
        broadcast(update_status(state, &Status.update_step_progress(&1, :drives, inserted)).status)
      end

      case Writer.insert_drives(car_id, valid, drive_progress) do
        {:ok, drives_with_ids} ->
          Writer.associate_positions_with_drives(drives_with_ids, state.date_to_pos_id)
          update_status(state, &Status.complete_step(&1, :drives))

        {:error, reason} ->
          Logger.error("Drive insert failed: #{inspect(reason)}")
          update_status(state, &Status.fail_step(&1, :drives, inspect(reason)))
      end
    else
      {:error, reason} ->
        Logger.error("Failed to import drives: #{inspect(reason)}")
        update_status(state, &Status.fail_step(&1, :drives, inspect(reason)))
    end
  end

  defp import_charging_data(%{status: %{state: {:error, _}}} = state, _, _, _), do: state
  defp import_charging_data(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    # First: import charging_processes
    with {:ok, cp_total} <- MysqlReader.count_charging_sessions(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :charging_processes, cp_total)),
         state = update_status(state, &Status.set_phase(&1, :charging_processes, :reading)),
         {:ok, cp_rows} <- MysqlReader.read_charging_sessions(conn, tl_car_id),
         {:ok, c_total} <- MysqlReader.count_charges(conn, tl_car_id),
         {:ok, c_rows} <- MysqlReader.read_charges(conn, tl_car_id) do

      state = update_status(state, &Status.set_phase(&1, :charging_processes, :mapping))

      # Map charges first (need them for enriching charging_processes)
      mapped_charges =
        Enum.map(c_rows, fn row ->
          charge = Mapper.map_charge(row, timezone)
          Map.put(charge, :tl_chargingstate_id, row["chargingstate_id"])
        end)

      cp_rows = filter_zero_duration(cp_rows, "charging processes")

      # Map and enrich charging_processes
      mapped_cps =
        Enum.map(cp_rows, fn row ->
          cp_attrs = Mapper.map_charging_process(row, timezone)
          tl_cs_id = row["id"]

          # Find charges belonging to this charging session
          session_charges =
            Enum.filter(mapped_charges, &(&1.tl_chargingstate_id == tl_cs_id))

          cp_attrs
          |> Mapper.enrich_charging_process(session_charges)
          |> Map.put(:_tl_id, tl_cs_id)
        end)

      # Index mapped_cps to track which ones pass validation
      indexed_cps =
        mapped_cps
        |> Enum.with_index()
        |> Enum.map(fn {cp, idx} -> Map.put(cp, :_idx, idx) end)

      state = update_status(state, &Status.set_phase(&1, :charging_processes, :validating))

      cps_for_validation = Enum.map(indexed_cps, &Map.drop(&1, [:_tl_id, :_idx]))

      {_valid_cps, cp_errors} = Validator.validate_charging_processes(cps_for_validation)

      warnings = Validator.format_warnings(cp_errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      # Collect indices of rows that have blocking errors
      error_indices =
        cp_errors
        |> Enum.filter(&(&1.severity == :error))
        |> Enum.map(& &1.row_id)
        |> MapSet.new()

      # Prepare {tl_id, cp_attrs} tuples for Writer, excluding errored rows
      valid_cps_with_tl_ids =
        indexed_cps
        |> Enum.reject(fn cp -> MapSet.member?(error_indices, cp._idx) end)
        |> Enum.map(fn cp ->
          {cp._tl_id, Map.drop(cp, [:_tl_id, :_idx])}
        end)

      # Mode B: filter out charging processes that overlap with existing ones
      {valid_cps_with_tl_ids, state} =
        if state.status.import_mode == :merge_tm_priority do
          state = update_status(state, &Status.set_phase(&1, :charging_processes, :filtering))
          existing = Writer.load_existing_ranges(car_id, :charging_processes)

          filtered =
            Enum.filter(valid_cps_with_tl_ids, fn {_tl_id, cp} ->
              Writer.filter_non_overlapping([cp], existing) != []
            end)

          {filtered, state}
        else
          {valid_cps_with_tl_ids, state}
        end

      state = update_status(state, &Status.set_phase(&1, :charging_processes, :inserting))

      cp_progress = fn inserted, _total ->
        broadcast(update_status(state, &Status.update_step_progress(&1, :charging_processes, inserted)).status)
      end

      {tl_cs_id_to_cp_id, state} =
        case Writer.insert_charging_processes(car_id, valid_cps_with_tl_ids, state.date_to_pos_id, cp_progress) do
          {:ok, mapping} ->
            {mapping, update_status(state, &Status.complete_step(&1, :charging_processes))}

          {:error, reason} ->
            Logger.error("Charging process insert failed: #{inspect(reason)}")
            {%{}, update_status(state, &Status.fail_step(&1, :charging_processes, inspect(reason)))}
        end

      # Now import charges (skip if CP insert failed)
      if tl_cs_id_to_cp_id == %{} and valid_cps_with_tl_ids != [] do
        Logger.warning("Skipping charge import because charging process insert failed")
        update_status(state, &Status.fail_step(&1, :charges, "Skipped: charging process insert failed"))
      else
        state = update_status(state, &Status.start_step(&1, :charges, c_total))
        state = update_status(state, &Status.set_phase(&1, :charges, :validating))

        {valid_charges, c_errors} = Validator.validate_charges(mapped_charges)
        warnings = Validator.format_warnings(c_errors)
        state = update_status(state, &Status.add_warnings(&1, warnings))

        state = update_status(state, &Status.set_phase(&1, :charges, :inserting))

        charge_progress = fn imported, _total ->
          broadcast(update_status(state, &Status.update_step_progress(&1, :charges, imported)).status)
        end

        case Writer.insert_charges(valid_charges, tl_cs_id_to_cp_id, charge_progress) do
          {:ok, _count} ->
            update_status(state, &Status.complete_step(&1, :charges))

          {:error, reason} ->
            Logger.error("Charge insert failed: #{inspect(reason)}")
            update_status(state, &Status.fail_step(&1, :charges, inspect(reason)))
        end
      end
    else
      {:error, reason} ->
        Logger.error("Failed to import charging data: #{inspect(reason)}")
        state
        |> update_status(&Status.fail_step(&1, :charging_processes, inspect(reason)))
        |> update_status(&Status.fail_step(&1, :charges, inspect(reason)))
    end
  end

  defp import_states(state, tl_car_id, car_id, timezone) do
    import_simple_entity(state, :states, %{
      count_fn: fn conn -> MysqlReader.count_states(conn, tl_car_id) end,
      read_fn: fn conn -> MysqlReader.read_states(conn, tl_car_id) end,
      map_fn: fn rows -> Enum.map(rows, &Mapper.map_state(&1, timezone)) end,
      filter_fn: fn mapped -> Enum.filter(mapped, &(&1.state != nil and &1.start_date != nil)) end,
      insert_fn: fn valid, progress -> Writer.insert_states(car_id, valid, progress) end,
      merge_entity: :states,
      car_id: car_id
    })
  end

  defp import_updates(state, tl_car_id, car_id, timezone) do
    import_simple_entity(state, :updates, %{
      count_fn: fn conn -> MysqlReader.count_updates(conn, tl_car_id) end,
      read_fn: fn conn -> MysqlReader.read_updates(conn, tl_car_id) end,
      map_fn: fn rows ->
        rows
        |> Enum.map(&Mapper.map_update(&1, timezone))
        |> Mapper.consolidate_updates()
        |> Mapper.add_update_end_dates()
      end,
      filter_fn: fn mapped -> mapped end,
      insert_fn: fn valid, progress -> Writer.insert_updates(car_id, valid, progress) end,
      merge_entity: :updates,
      car_id: car_id
    })
  end

  defp import_simple_entity(%{status: %{state: {:error, _}}} = state, _step, _opts), do: state

  defp import_simple_entity(state, step, opts) do
    conn = state.mysql_conn

    with {:ok, total} <- opts.count_fn.(conn),
         state = update_status(state, &Status.start_step(&1, step, total)),
         state = update_status(state, &Status.set_phase(&1, step, :reading)),
         {:ok, rows} <- opts.read_fn.(conn) do

      state = update_status(state, &Status.set_phase(&1, step, :mapping))
      valid = rows |> opts.map_fn.() |> opts.filter_fn.()

      {valid, state} = maybe_filter_overlapping(state, step, opts.merge_entity, opts.car_id, valid)

      state = update_status(state, &Status.set_phase(&1, step, :inserting))

      progress_fn = fn inserted, _total ->
        broadcast(update_status(state, &Status.update_step_progress(&1, step, inserted)).status)
      end

      case opts.insert_fn.(valid, progress_fn) do
        {:ok, _count} -> update_status(state, &Status.complete_step(&1, step))
        {:error, reason} -> update_status(state, &Status.fail_step(&1, step, inspect(reason)))
      end
    else
      {:error, reason} -> update_status(state, &Status.fail_step(&1, step, inspect(reason)))
    end
  end

  defp maybe_filter_overlapping(state, step, entity, car_id, valid) do
    if state.status.import_mode == :merge_tm_priority do
      state = update_status(state, &Status.set_phase(&1, step, :filtering))
      existing = Writer.load_existing_ranges(car_id, entity)
      {Writer.filter_non_overlapping(valid, existing), state}
    else
      {valid, state}
    end
  end

  # Filters out rows where StartDate == EndDate (zero-duration entries from TeslaLogger,
  # typically brief wake-ups). These would otherwise cause cascading 1-second overlaps
  # when ensure_end_after_start adds +1s to make end > start.
  defp filter_zero_duration(rows, label) do
    {kept, dropped} =
      Enum.split_with(rows, fn row ->
        not (row["StartDate"] == row["EndDate"] and row["StartDate"] != nil)
      end)

    if dropped != [] do
      Logger.info("Filtered #{length(dropped)} zero-duration #{label} (start == end)")
    end

    kept
  end

  defp finalize(state) do
    # Trigger geocoding
    state = update_status(state, &Status.start_step(&1, :geocoding))
    case Repair.trigger_run() do
      :ok -> :ok
      error -> Logger.warning("Repair.trigger_run returned: #{inspect(error)}")
    end
    state = update_status(state, &Status.complete_step(&1, :geocoding))

    # Run post-import validation
    state = update_status(state, &Status.start_step(&1, :validation))
    state = run_post_import_validation(state)
    state = update_status(state, &Status.complete_step(&1, :validation))

    # Apply geofences to imported drives and charging processes
    Logger.info("Applying geofences to imported data...")
    TeslaMate.Locations.apply_all_geofences()
    Logger.info("Geofence assignment complete.")

    # Complete
    state = update_status(state, &Status.set_state(&1, :complete))
    Logger.info("TeslaLogger import complete!")
    state
  end

  defp run_post_import_validation(state) do
    Enum.reduce(state.car_mapping, state, fn {_tl_id, car}, state ->
      # Count positions without drive_id
      orphan_positions =
        Repo.aggregate(
          from(p in TeslaMate.Log.Position, where: p.car_id == ^car.id and is_nil(p.drive_id)),
          :count
        )

      if orphan_positions > 0 do
        update_status(state, &Status.add_warning(&1, "Car #{car.id}: #{orphan_positions} positions without drive assignment"))
      else
        state
      end
    end)
  end

  ## Car creation

  defp create_or_find_car(tl_car, user_mapping) do
    tl_car_id = tl_car["id"]
    mysql_vin = tl_car["vin"]
    display_name = tl_car["display_name"]

    # Check if user provided mapping for this car
    user_car_info = Map.get(user_mapping, tl_car_id, %{})

    # Priority: user VIN > MySQL VIN
    vin = user_car_info[:vin] || mysql_vin
    eid = user_car_info[:eid] || tl_car_id * 1000
    vid = user_car_info[:vid] || tl_car_id * 1000 + 1

    # VIN is required — abort if neither MySQL nor user provides one
    vin = if vin in [nil, ""], do: nil, else: vin

    case vin do
      nil ->
        {:error, :vin_required}

      vin ->
        case Log.get_car_by(vin: vin) do
          %Car{} = car ->
            {:ok, Repo.preload(car, :settings)}

          nil ->
            create_import_car(eid, vid, vin, display_name)
        end
    end
  end

  defp create_import_car(eid, vid, vin, name) do
    attrs = %{
      eid: eid,
      vid: vid,
      vin: vin,
      name: name
    }

    case Log.create_car(attrs) do
      {:ok, car} ->
        # Disable API polling for imported cars
        car = Repo.preload(car, :settings)

        case car.settings
             |> CarSettings.changeset(%{
               suspend_min: 0,
               suspend_after_idle_min: 99999,
               use_streaming_api: false,
               enabled: false
             })
             |> Repo.update() do
          {:ok, _settings} -> :ok
          {:error, reason} -> Logger.warning("Failed to update car settings: #{inspect(reason)}")
        end

        {:ok, car}

      {:error, _} = err ->
        err
    end
  end

  ## Helpers

  defp get_position_attrs_for_dates(dates, date_to_pos_id) do
    pos_ids =
      dates
      |> Enum.map(&Map.get(date_to_pos_id, &1))
      |> Enum.reject(&is_nil/1)

    case pos_ids do
      [] ->
        []

      ids ->
        from(p in TeslaMate.Log.Position,
          where: p.id in ^ids,
          order_by: p.date,
          select: %{
            odometer: p.odometer,
            ideal_battery_range_km: p.ideal_battery_range_km,
            rated_battery_range_km: p.rated_battery_range_km,
            inside_temp: p.inside_temp,
            outside_temp: p.outside_temp
          }
        )
        |> Repo.all()
    end
  end

  defp find_positions_in_range(_sorted_pos_array, nil, _end_date), do: []

  defp find_positions_in_range(sorted_pos_array, start_date, end_date) do
    Writer.find_in_sorted_array(sorted_pos_array, start_date, end_date)
  end

  defp update_status(state, fun) do
    new_status = fun.(state.status)
    broadcast(new_status)
    %{state | status: new_status}
  end

  defp broadcast(status) do
    Phoenix.PubSub.broadcast(TeslaMate.PubSub, @topic, {:teslalogger_import, status})
  end
end
