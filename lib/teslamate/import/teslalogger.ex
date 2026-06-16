defmodule TeslaMate.Import.TeslaLogger do
  @moduledoc false

  use GenServer

  require Logger

  import Ecto.Query

  alias __MODULE__.{Status, MysqlReader, Mapper, Preview, Validator, Writer}
  alias TeslaMate.{Repo, Repair}
  alias TeslaMate.Log
  alias TeslaMate.Log.{Car, ChargingProcess, Drive, ImportMetadata, Position}
  alias TeslaMate.Settings.CarSettings

  defstruct [
    :config,
    :mysql_conn,
    status: Status.initial(),
    car_mapping: %{},
    # nil = import all cars; a list restricts the import to those TeslaLogger car ids
    car_ids: nil,
    date_to_pos_id: %{},
    pos_attrs_by_date: %{}
  ]

  @name __MODULE__
  @topic "#{@name}/state"

  # Buffer around drive/charge ranges so boundary positions (needed for
  # start/end_position_id and charging_process position_id) are kept.
  @active_range_buffer_seconds 60

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def get_status, do: GenServer.call(@name, :get_status)

  def run(car_mapping \\ %{}, opts \\ []),
    do: GenServer.call(@name, {:run, car_mapping, opts}, :infinity)

  def preflight, do: GenServer.call(@name, :preflight, :infinity)
  def preview, do: GenServer.call(@name, :preview)
  def configure(params), do: GenServer.call(@name, {:configure, params})
  def reset, do: GenServer.call(@name, :reset)
  def enabled?, do: is_pid(Process.whereis(@name))
  def subscribe, do: Phoenix.PubSub.subscribe(TeslaMate.PubSub, @topic)

  @impl true
  def init(opts) do
    # Import/preflight tasks are linked — trap exits so a task crash is reported
    # via status instead of taking down this server (and its config/connection).
    Process.flag(:trap_exit, true)

    config = Keyword.get(opts, :config)
    # Env vars only pre-fill the connection form; the UI flow always starts
    # unconfigured and the user confirms via "Test Connection".
    effective_config =
      if config && Enum.any?(config, fn {_, v} -> v != nil end), do: config, else: nil

    status = %{Status.initial() | state: :unconfigured}
    {:ok, %__MODULE__{config: effective_config, status: status}}
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

  def handle_call(:preview, _from, state) do
    cond do
      state.status.state != :idle ->
        {:reply, {:error, :not_ready}, state}

      state.status.preview == :loading ->
        {:reply, :ok, state}

      state.mysql_conn == nil ->
        {:reply, {:error, :not_connected}, state}

      true ->
        send(self(), :run_preview)
        state = update_status(state, &Status.set_preview(&1, :loading))
        {:reply, :ok, state}
    end
  end

  def handle_call({:configure, params}, _from, state) do
    stop_mysql(state.mysql_conn)

    new_config = [
      host: params[:host],
      port: params[:port],
      username: params[:username],
      password: params[:password],
      database: params[:database],
      timezone: params[:timezone]
    ]

    new_status = %{Status.initial() | state: :unconfigured}
    broadcast(new_status)
    {:reply, :ok, %{state | config: new_config, mysql_conn: nil, status: new_status}}
  end

  def handle_call(:reset, _from, state) do
    stop_mysql(state.mysql_conn)
    new_status = %{Status.initial() | state: :unconfigured}
    broadcast(new_status)
    {:reply, :ok, %{state | config: nil, mysql_conn: nil, status: new_status}}
  end

  def handle_call({:run, car_mapping, opts}, _from, state) do
    cond do
      state.status.state in [:running, :preflight] ->
        {:reply, {:error, :already_running}, state}

      state.config == nil ->
        {:reply, {:error, :not_configured}, state}

      true ->
        mode = Keyword.get(opts, :mode, :clean)
        car_ids = Keyword.get(opts, :car_ids)
        # Fresh position lookup per run — stale entries from a previous run would
        # point at deleted rows.
        state = %{state | car_mapping: car_mapping, car_ids: car_ids, date_to_pos_id: %{}}
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

  def handle_info(:run_preview, state) do
    parent = self()
    conn = state.mysql_conn
    timezone = state.config[:timezone]
    car_info = state.status.mysql_car_info

    {:ok, pid} =
      Task.start_link(fn ->
        result =
          Enum.reduce_while(car_info, {:ok, []}, fn info, {:ok, acc} ->
            case Preview.build(conn, info, timezone) do
              {:ok, preview} -> {:cont, {:ok, [preview | acc]}}
              {:error, reason} -> {:halt, {:error, inspect(reason)}}
            end
          end)

        result =
          case result do
            {:ok, previews} -> {:ok, Enum.reverse(previews)}
            error -> error
          end

        send(parent, {:preview_done, result})
      end)

    Process.monitor(pid)
    {:noreply, state}
  end

  def handle_info({:preview_done, result}, state) do
    {:noreply, update_status(state, &Status.set_preview(&1, result))}
  end

  def handle_info(:start_import, state) do
    parent = self()

    # Mark :running in the GenServer's own state BEFORE spawning — the task only
    # mutates its private copy, so without this the busy-guard in handle_call
    # would wave through a second concurrent import.
    state = update_status(state, &Status.set_state(&1, :running))

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
    {:noreply,
     %{state | status: result_state.status, date_to_pos_id: result_state.date_to_pos_id}}
  end

  # Task crashes arrive as :EXIT (tasks are linked, exits are trapped) and as
  # :DOWN (monitored). Whichever arrives first records the error; the second
  # becomes a no-op because the state is no longer :running/:preflight.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:noreply, handle_task_crash(state, reason)}
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state),
    do: {:noreply, handle_task_crash(state, reason)}

  defp handle_task_crash(state, reason) do
    cond do
      state.status.state in [:running, :preflight] ->
        Logger.error("Import/preflight task crashed: #{inspect(reason)}")
        update_status(state, &Status.set_state(&1, {:error, "Task crashed: #{inspect(reason)}"}))

      state.status.preview == :loading ->
        Logger.error("Preview task crashed: #{inspect(reason)}")

        update_status(
          state,
          &Status.set_preview(&1, {:error, "Preview crashed: #{inspect(reason)}"})
        )

      true ->
        state
    end
  end

  defp stop_mysql(nil), do: :ok

  defp stop_mysql(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn)
  catch
    :exit, _ -> :ok
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

        state =
          update_status(
            state,
            &Status.update_preflight_step(&1, :connecting, {:error, detail}, detail)
          )

        update_status(state, &Status.set_state(&1, {:error, detail}))

      {:ok, state} ->
        state = update_status(state, &Status.update_preflight_step(&1, :connecting, :complete))
        sync_preflight(parent, state)
        run_preflight_validate_timezone(state, parent)
    end
  end

  defp run_preflight_validate_timezone(state, parent) do
    state =
      update_status(state, &Status.update_preflight_step(&1, :validating_timezone, :running))

    sync_preflight(parent, state)

    timezone = state.config[:timezone] || "UTC"

    case DateTime.now(timezone) do
      {:ok, _} ->
        state =
          update_status(
            state,
            &Status.update_preflight_step(&1, :validating_timezone, :complete, timezone)
          )

        sync_preflight(parent, state)
        run_preflight_check_schema(state, parent)

      {:error, _} ->
        detail = "Unknown timezone: #{timezone}"

        state =
          update_status(
            state,
            &Status.update_preflight_step(&1, :validating_timezone, {:error, detail}, detail)
          )

        update_status(state, &Status.set_state(&1, {:error, detail}))
    end
  end

  defp run_preflight_check_schema(state, parent) do
    state = update_status(state, &Status.update_preflight_step(&1, :checking_schema, :running))
    sync_preflight(parent, state)

    case MysqlReader.check_schema(state.mysql_conn) do
      :ok ->
        state =
          update_status(state, &Status.update_preflight_step(&1, :checking_schema, :complete))

        sync_preflight(parent, state)
        run_preflight_read_source(state, parent)

      {:error, reason} ->
        Logger.error("Preflight schema check failed: #{reason}")

        state =
          update_status(
            state,
            &Status.update_preflight_step(&1, :checking_schema, {:error, reason}, reason)
          )

        update_status(state, &Status.set_state(&1, {:error, reason}))
    end
  end

  defp run_preflight_read_source(state, parent) do
    state = update_status(state, &Status.update_preflight_step(&1, :reading_source, :running))
    sync_preflight(parent, state)

    case MysqlReader.read_source_info(state.mysql_conn) do
      {:ok, car_info} ->
        count = length(car_info)
        detail = "Found #{count} car(s)"
        Logger.info("Preflight: #{detail}")

        Enum.each(car_info, fn c ->
          if c["vin"] && c["vin"] != "" do
            Logger.info(
              "  Car #{c["id"]}: VIN #{c["vin"]} (#{c["display_name"]}), #{c["drive_count"]} drives, #{c["charge_count"]} charges"
            )
          else
            Logger.warning("  Car #{c["id"]}: No VIN found (#{c["display_name"]})")
          end
        end)

        state =
          update_status(
            state,
            &Status.update_preflight_step(&1, :reading_source, :complete, detail)
          )

        state = update_status(state, fn s -> %{s | mysql_car_info: car_info} end)
        sync_preflight(parent, state)
        run_preflight_check_target(state, parent)

      {:error, reason} ->
        Logger.error("Preflight read failed: #{reason}")

        state =
          update_status(
            state,
            &Status.update_preflight_step(&1, :reading_source, {:error, reason}, reason)
          )

        update_status(state, &Status.set_state(&1, {:error, reason}))
    end
  end

  defp run_preflight_check_target(state, parent) do
    state = update_status(state, &Status.update_preflight_step(&1, :checking_target, :running))
    sync_preflight(parent, state)

    {car_info_with_tm, any_has_data} =
      Enum.map_reduce(state.status.mysql_car_info, false, fn car_info, has_data_acc ->
        case Writer.check_tm_data_for_vin(car_info["vin"]) do
          {:ok, nil} ->
            enriched = Map.merge(car_info, %{"tm_car_id" => nil, "tm_data_counts" => nil})
            {enriched, has_data_acc}

          {:ok, %{tm_car_id: tm_id, tm_data_counts: counts}} ->
            has_data = map_size(counts) > 0
            enriched = Map.merge(car_info, %{"tm_car_id" => tm_id, "tm_data_counts" => counts})
            {enriched, has_data_acc or has_data}
        end
      end)

    detail = if any_has_data, do: "Existing TeslaMate data found", else: "No existing data"

    state =
      update_status(state, fn s ->
        %{s | mysql_car_info: car_info_with_tm, tm_has_data: any_has_data}
      end)

    state =
      update_status(state, &Status.update_preflight_step(&1, :checking_target, :complete, detail))

    update_status(state, &Status.set_state(&1, :idle))
  end

  # Sends intermediate preflight state to GenServer so get_status() stays current
  defp sync_preflight(parent, state) do
    send(parent, {:preflight_update, state.status})
  end

  # Minimal preflight for the ensure_connected path (import without prior UI preflight)
  defp run_preflight_check(state) do
    with :ok <- MysqlReader.check_schema(state.mysql_conn),
         {:ok, car_info} <- MysqlReader.read_source_info(state.mysql_conn) do
      Logger.info("Preflight check passed — found #{length(car_info)} car(s)")
      state = update_status(state, fn s -> %{s | mysql_car_info: car_info} end)
      {:ok, state}
    else
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

            msg =
              "Car #{car.vin || car.id} already has data (#{counts_str}). Use a merge mode or empty the database first."

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
      {:ok, all_tl_cars} ->
        # Restrict to the cars selected in the wizard (nil = all).
        tl_cars =
          case state.car_ids do
            nil -> all_tl_cars
            ids -> Enum.filter(all_tl_cars, fn c -> c["id"] in ids end)
          end

        Logger.info(
          "Found #{length(all_tl_cars)} car(s) in TeslaLogger, importing #{length(tl_cars)}"
        )

        car_count = length(tl_cars)
        state = update_status(state, fn s -> %{s | car_count: car_count} end)
        state = update_status(state, &Status.start_step(&1, :cars, car_count))

        car_mapping =
          Enum.reduce_while(tl_cars, {:ok, %{}, []}, fn tl_car, {:ok, acc, skipped} ->
            tl_car_id = tl_car["id"]

            case create_or_find_car(tl_car, state.car_mapping) do
              {:ok, car} ->
                Logger.info(
                  "Mapped TeslaLogger car #{tl_car_id} -> TeslaMate car #{car.id} (#{car.name || car.vin})"
                )

                {:cont, {:ok, Map.put(acc, tl_car_id, car), skipped}}

              {:error, :vin_required} ->
                msg =
                  "TeslaLogger car #{tl_car_id} (#{tl_car["display_name"]}) has no VIN. Please provide a VIN in the import form."

                Logger.error(msg)
                {:halt, {:error, msg}}

              {:error, reason} ->
                msg =
                  "Skipped TeslaLogger car #{tl_car_id} (#{tl_car["display_name"]}): #{inspect(reason)} — its data will NOT be imported"

                Logger.warning(msg)
                {:cont, {:ok, acc, [msg | skipped]}}
            end
          end)

        case car_mapping do
          {:ok, mapping, skipped} ->
            state = %{state | car_mapping: mapping}
            state = update_status(state, &Status.add_warnings(&1, skipped))
            {:ok, update_status(state, &Status.complete_step(&1, :cars))}

          {:error, msg} ->
            {:error, msg, update_status(state, &Status.fail_step(&1, :cars, msg))}
        end

      {:error, reason} ->
        Logger.error("Failed to read cars: #{inspect(reason)}")

        {:error, inspect(reason),
         update_status(state, &Status.fail_step(&1, :cars, inspect(reason)))}
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

        # Fresh per-car position lookup — a shared map would associate drives and
        # charging processes with positions of another car that drove at the same time.
        state = %{state | date_to_pos_id: %{}, pos_attrs_by_date: %{}}

        # Mode C: Pre-delete all overlapping data in FK-safe order BEFORE importing
        case maybe_pre_delete_overlapping(state, tl_car_id, car.id, timezone) do
          {:error, reason, state} ->
            update_status(
              state,
              &Status.set_state(&1, {:error, "Pre-deletion failed: #{inspect(reason)}"})
            )

          {:ok, state} ->
            state
            |> import_positions(tl_car_id, car.id, timezone)
            |> import_drives(tl_car_id, car.id, timezone)
            |> import_charging_data(tl_car_id, car.id, timezone)
            |> import_states(tl_car_id, car.id, timezone)
            |> import_updates(tl_car_id, car.id, timezone)
            |> then(&%{&1 | pos_attrs_by_date: %{}})
        end
      end
    end)
  end

  # Reads drive and charging session {start, end} ranges from TeslaLogger.
  # Used both for Mode C pre-deletion and for filtering idle positions.
  defp read_active_ranges(conn, tl_car_id, timezone) do
    with {:ok, drive_rows} <- MysqlReader.read_drives(conn, tl_car_id),
         {:ok, cp_rows} <- MysqlReader.read_charging_sessions(conn, tl_car_id) do
      to_range = fn rows, map_fn ->
        rows
        |> Enum.map(fn r ->
          m = map_fn.(r, timezone)
          {m.start_date, m.end_date}
        end)
        |> Enum.reject(fn {s, _} -> is_nil(s) end)
      end

      {:ok, to_range.(drive_rows, &Mapper.map_drive/2),
       to_range.(cp_rows, &Mapper.map_charging_process/2)}
    end
  end

  defp maybe_pre_delete_overlapping(state, tl_car_id, car_id, timezone) do
    if state.status.import_mode != :merge_tl_priority do
      {:ok, state}
    else
      Logger.info("Mode C: Pre-deleting overlapping TeslaMate data for car #{car_id}...")
      conn = state.mysql_conn

      with {:ok, drive_ranges, cp_ranges} <- read_active_ranges(conn, tl_car_id, timezone),
           {:ok, state_rows} <- MysqlReader.read_states(conn, tl_car_id) do
        state_ranges =
          state_rows
          |> Enum.map(fn r ->
            m = Mapper.map_state(r, timezone)
            {m.start_date, m.end_date}
          end)
          |> Enum.reject(fn {s, _} -> is_nil(s) end)

        # Each entity is deleted only where TL re-inserts the same kind of data.
        # Positions are imported within drive/charge ranges (±buffer), so only
        # those windows are cleared — TM data in TL gaps stays untouched.
        pos_ranges =
          (drive_ranges ++ cp_ranges)
          |> Enum.map(fn {s, e} ->
            {DateTime.add(s, -@active_range_buffer_seconds, :second),
             e && DateTime.add(e, @active_range_buffer_seconds, :second)}
          end)

        ranges_by_entity = %{
          positions: Writer.consolidate_ranges(pos_ranges),
          drives: Writer.consolidate_ranges(drive_ranges),
          charging_processes: Writer.consolidate_ranges(cp_ranges),
          states: Writer.consolidate_ranges(state_ranges),
          # TL updates span from version-seen until next version, covering the whole
          # logging period — use state coverage as the conservative delete window.
          updates: Writer.consolidate_ranges(state_ranges)
        }

        Writer.delete_overlapping_data(car_id, ranges_by_entity)
        {:ok, state}
      else
        {:error, reason} ->
          Logger.error(
            "Failed to compute TeslaLogger time ranges for pre-deletion: #{inspect(reason)}"
          )

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
            update_status(state, &Status.update_step_progress(&1, :positions, new_count))
          end

          {result, new_count}
        end)

      # Merge TPMS data if available
      mapped =
        case MysqlReader.read_tpms(conn, tl_car_id) do
          {:ok, tpms_rows} when tpms_rows != [] ->
            Logger.info("Merging #{length(tpms_rows)} TPMS readings into positions")
            Mapper.merge_tpms(mapped, tpms_rows, timezone)

          _ ->
            mapped
        end

      # Keep only positions within drive or charging session time ranges.
      # TeslaLogger logs positions continuously (parking, sleeping) which pollutes
      # dashboards like the Speed Histogram with GPS jitter at 0 km/h.
      mapped = filter_positions_to_active_ranges(mapped, conn, tl_car_id, timezone)

      state = update_status(state, &Status.set_phase(&1, :positions, :validating))

      {valid, errors} = Validator.validate_positions(mapped)
      warnings = Validator.format_warnings(errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      # Mode B: drop positions in periods covered by existing TM drives/charges.
      # TM and TL poll independently, so exact-timestamp dedup alone matches almost
      # nothing — overlapping periods would end up with doubled GPS tracks.
      {valid, state} =
        if state.status.import_mode == :merge_tm_priority do
          state = update_status(state, &Status.set_phase(&1, :positions, :filtering))
          {filter_positions_against_tm_ranges(valid, car_id), state}
        else
          {valid, state}
        end

      state = update_status(state, &Status.set_phase(&1, :positions, :inserting))

      progress_fn = fn imported, _total ->
        update_status(state, &Status.update_step_progress(&1, :positions, imported))
      end

      case Writer.insert_positions(car_id, valid, progress_fn) do
        {:ok, new_date_map} ->
          # Slim per-date attrs so drive enrichment can run from memory instead of
          # re-querying every drive's positions from Postgres. Keyed by unix seconds —
          # DateTimes returned from Postgres differ in microsecond precision from the
          # mapped ones, so struct equality would never match.
          pos_attrs_by_date =
            Map.new(valid, fn p ->
              {DateTime.to_unix(p.date, :second),
               Map.take(p, [
                 :odometer,
                 :ideal_battery_range_km,
                 :rated_battery_range_km,
                 :inside_temp,
                 :outside_temp
               ])}
            end)

          state = %{state | date_to_pos_id: new_date_map, pos_attrs_by_date: pos_attrs_by_date}
          update_status(state, &Status.complete_step(&1, :positions, map_size(new_date_map)))

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

          # Enrich with position data (from memory — one DB query per drive would
          # make thousands of drives crawl)
          pos_attrs =
            sorted_pos_array
            |> find_positions_in_range(drive_attrs.start_date, drive_attrs.end_date)
            |> Enum.map(&Map.get(state.pos_attrs_by_date, DateTime.to_unix(&1, :second)))
            |> Enum.reject(&is_nil/1)

          enriched = Mapper.enrich_drive(drive_attrs, pos_attrs)

          new_count = count + 1

          if rem(new_count, 500) == 0 do
            update_status(state, &Status.update_step_progress(&1, :drives, new_count))
          end

          {enriched, new_count}
        end)

      mapped = filter_phantom_drives(mapped)

      state = update_status(state, &Status.set_phase(&1, :drives, :validating))

      {valid, errors} = Validator.validate_drives(mapped)
      warnings = Validator.format_warnings(errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      {valid, state} = maybe_filter_overlapping(state, :drives, :drives, car_id, valid)

      state = update_status(state, &Status.set_phase(&1, :drives, :inserting))

      drive_progress = fn inserted, _total ->
        update_status(state, &Status.update_step_progress(&1, :drives, inserted))
      end

      case Writer.insert_drives(car_id, valid, drive_progress) do
        {:ok, drives_with_ids} ->
          Writer.associate_positions_with_drives(drives_with_ids, state.date_to_pos_id)
          update_status(state, &Status.complete_step(&1, :drives, length(drives_with_ids)))

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

      # Correct DC/AC classification per session using average power.
      # TeslaLogger row-level DC detection is unreliable — session avg is definitive.
      mapped_charges =
        mapped_charges
        |> Enum.group_by(& &1.tl_chargingstate_id)
        |> Enum.flat_map(fn {_id, charges} -> Mapper.correct_dc_classification(charges) end)

      cp_rows = filter_zero_duration(cp_rows, "charging processes")
      cp_rows = filter_phantom_sessions(cp_rows)

      # Map and enrich charging_processes
      mapped_cps =
        Enum.map(cp_rows, fn row ->
          cp_attrs = Mapper.map_charging_process(row, timezone)
          tl_cs_id = row["id"]

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
        update_status(state, &Status.update_step_progress(&1, :charging_processes, inserted))
      end

      {tl_cs_id_to_cp_id, state} =
        case Writer.insert_charging_processes(
               car_id,
               valid_cps_with_tl_ids,
               state.date_to_pos_id,
               cp_progress
             ) do
          {:ok, mapping} ->
            {mapping,
             update_status(
               state,
               &Status.complete_step(&1, :charging_processes, map_size(mapping))
             )}

          {:error, reason} ->
            Logger.error("Charging process insert failed: #{inspect(reason)}")

            {%{},
             update_status(state, &Status.fail_step(&1, :charging_processes, inspect(reason)))}
        end

      # Now import charges (skip if CP insert failed)
      if tl_cs_id_to_cp_id == %{} and valid_cps_with_tl_ids != [] do
        Logger.warning("Skipping charge import because charging process insert failed")

        update_status(
          state,
          &Status.fail_step(&1, :charges, "Skipped: charging process insert failed")
        )
      else
        state = update_status(state, &Status.start_step(&1, :charges, c_total))
        state = update_status(state, &Status.set_phase(&1, :charges, :validating))

        {valid_charges, c_errors} = Validator.validate_charges(mapped_charges)
        warnings = Validator.format_warnings(c_errors)
        state = update_status(state, &Status.add_warnings(&1, warnings))

        state = update_status(state, &Status.set_phase(&1, :charges, :inserting))

        charge_progress = fn imported, _total ->
          update_status(state, &Status.update_step_progress(&1, :charges, imported))
        end

        case Writer.insert_charges(valid_charges, tl_cs_id_to_cp_id, charge_progress) do
          {:ok, count} ->
            update_status(state, &Status.complete_step(&1, :charges, count))

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

      {valid, state} =
        maybe_filter_overlapping(state, step, opts.merge_entity, opts.car_id, valid)

      state = update_status(state, &Status.set_phase(&1, step, :inserting))

      progress_fn = fn inserted, _total ->
        update_status(state, &Status.update_step_progress(&1, step, inserted))
      end

      case opts.insert_fn.(valid, progress_fn) do
        {:ok, count} -> update_status(state, &Status.complete_step(&1, step, count))
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

  # Filter phantom charging sessions where TeslaLogger's own charge_energy_added
  # (set at session end) is nil or near-zero. These are brief wake-ups where the
  # charging rows still carry stale cumulative values from the previous real session,
  # producing phantom entries with impossibly high energy/power readings.
  defp filter_phantom_sessions(cp_rows) do
    {kept, dropped} =
      Enum.split_with(cp_rows, fn row ->
        energy = row["charge_energy_added"]

        energy_val =
          cond do
            is_number(energy) -> energy + 0.0
            is_struct(energy, Decimal) -> Decimal.to_float(energy)
            true -> nil
          end

        # Keep session if TL recorded meaningful energy, or if energy is unknown (nil).
        # Only drop when TL explicitly says ~0 kWh — that's a phantom wake-up.
        energy_val == nil or energy_val > 0.1
      end)

    if dropped != [] do
      Logger.info(
        "Filtered #{length(dropped)} phantom charging sessions (TL charge_energy_added nil or ~0)"
      )
    end

    kept
  end

  # Keeps only positions within drive or charging session time ranges (±buffer).
  # TeslaLogger logs positions continuously, even while parked or sleeping; these
  # idle positions pollute dashboards (e.g. Speed Histogram shows 96% at 0-10 km/h
  # from GPS jitter).
  defp filter_positions_to_active_ranges(positions, conn, tl_car_id, timezone) do
    case read_active_ranges(conn, tl_car_id, timezone) do
      {:ok, [], []} ->
        Logger.warning("No drives or charging sessions found — keeping all positions")
        positions

      {:ok, drive_ranges, charge_ranges} ->
        unix_ranges = to_consolidated_unix_ranges(drive_ranges ++ charge_ranges)
        before = length(positions)

        filtered =
          Enum.filter(positions, fn pos ->
            case pos.date do
              nil -> false
              date -> unix_in_ranges?(DateTime.to_unix(date, :second), unix_ranges)
            end
          end)

        dropped = before - length(filtered)

        if dropped > 0 do
          Logger.info(
            "Filtered #{dropped} idle positions (kept #{length(filtered)} of #{before} " <>
              "within #{length(drive_ranges)} drives + #{length(charge_ranges)} charging sessions)"
          )
        end

        filtered

      {:error, reason} ->
        Logger.warning(
          "Could not read active ranges (#{inspect(reason)}) — keeping all positions"
        )

        positions
    end
  end

  # Mode B: rejects positions that fall within existing TeslaMate drive/charge
  # ranges or match an existing position timestamp exactly.
  defp filter_positions_against_tm_ranges(positions, car_id) do
    tm_ranges =
      (Writer.load_existing_ranges(car_id, :drives) ++
         Writer.load_existing_ranges(car_id, :charging_processes))
      |> Enum.reject(fn {s, _} -> is_nil(s) end)
      |> to_consolidated_unix_ranges()

    existing_set = Writer.load_existing_position_dates(car_id)
    before = length(positions)

    kept =
      Enum.reject(positions, fn pos ->
        unix = DateTime.to_unix(pos.date, :second)
        MapSet.member?(existing_set, unix) or unix_in_ranges?(unix, tm_ranges)
      end)

    dropped = before - length(kept)

    if dropped > 0 do
      Logger.info("Mode B: skipped #{dropped} positions overlapping existing TeslaMate data")
    end

    kept
  end

  # Converts {DateTime, DateTime | nil} ranges into a sorted, consolidated tuple of
  # buffered unix ranges for binary search. Open-ended ranges are capped at 24h.
  defp to_consolidated_unix_ranges(ranges) do
    ranges
    |> Enum.map(fn {start_date, end_date} ->
      s = DateTime.to_unix(start_date, :second) - @active_range_buffer_seconds

      e =
        if end_date,
          do: DateTime.to_unix(end_date, :second) + @active_range_buffer_seconds,
          else: s + 86_400

      {s, e}
    end)
    |> Enum.sort()
    |> consolidate_unix_ranges()
    |> List.to_tuple()
  end

  # Consolidates sorted {start, end} unix ranges by merging overlapping/adjacent ranges.
  defp consolidate_unix_ranges([]), do: []

  defp consolidate_unix_ranges([first | rest]) do
    Enum.reduce(rest, [first], fn {s, e}, [{cs, ce} | acc] ->
      if s <= ce do
        # Overlapping or adjacent — extend current range
        [{cs, max(ce, e)} | acc]
      else
        # Gap — start new range
        [{s, e}, {cs, ce} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Binary search to check if a unix timestamp falls within any consolidated range.
  # `ranges` is a tuple of {start, end} pairs for O(1) random access.
  defp unix_in_ranges?(unix, ranges_tuple) do
    unix_in_ranges_bs?(unix, ranges_tuple, 0, tuple_size(ranges_tuple) - 1)
  end

  defp unix_in_ranges_bs?(_unix, _ranges, lo, hi) when lo > hi, do: false

  defp unix_in_ranges_bs?(unix, ranges, lo, hi) do
    mid = div(lo + hi, 2)
    {s, e} = elem(ranges, mid)

    cond do
      unix < s -> unix_in_ranges_bs?(unix, ranges, lo, mid - 1)
      unix > e -> unix_in_ranges_bs?(unix, ranges, mid + 1, hi)
      true -> true
    end
  end

  # TeslaLogger frequently creates phantom drives from brief wake-ups or GPS noise.
  # These show up as entries with zero/tiny distance or nil positions. We drop a drive
  # when ANY of these conditions is true:
  #   1. distance is nil (no position data at all)
  #   2. distance <= 0 (car didn't actually move)
  #   3. distance < 0.5 km AND duration < 2 minutes (micro-movement, GPS jitter)
  defp filter_phantom_drives(drives) do
    {kept, dropped} =
      Enum.split_with(drives, fn drive ->
        distance = drive[:distance]
        duration = drive[:duration_min]

        cond do
          # No position data → phantom
          is_nil(distance) -> false
          # Didn't move or moved backwards → phantom
          distance <= 0 -> false
          # Micro-movement: less than 500m in under 2 minutes → phantom
          distance < 0.5 and is_number(duration) and duration < 2 -> false
          # Real drive
          true -> true
        end
      end)

    if dropped != [] do
      Logger.info("Filtered #{length(dropped)} phantom drives (no movement or micro-movement)")
    end

    kept
  end

  # Recalculate efficiency factor for each imported car from charging data.
  # Same logic as TeslaMate's Log.recalculate_efficiency:
  # efficiency = charge_energy_added / (end_rated_range_km - start_rated_range_km)
  defp recalculate_car_efficiencies(state) do
    Enum.each(state.car_mapping, fn {_tl_id, car} ->
      query =
        from cp in ChargingProcess,
          select: {
            fragment(
              "round(? / nullif(? - ?, 0), 4)",
              cp.charge_energy_added,
              cp.end_ideal_range_km,
              cp.start_ideal_range_km
            ),
            count()
          },
          where:
            cp.car_id == ^car.id and cp.duration_min > 10 and cp.end_battery_level <= 95 and
              not is_nil(cp.end_ideal_range_km) and not is_nil(cp.start_ideal_range_km) and
              cp.charge_energy_added > 0.0,
          group_by: 1,
          order_by: [desc: 2],
          limit: 1

      case Repo.one(query) do
        {factor, n} when not is_nil(factor) and n >= 2 ->
          factor_float = Decimal.to_float(factor)

          if factor_float > 0 do
            Logger.info(
              "Car #{car.id}: derived efficiency #{Float.round(factor_float * 1000, 1)} Wh/km (#{n}x confirmed)"
            )

            Car
            |> Repo.get!(car.id)
            |> Car.changeset(%{efficiency: factor_float})
            |> Repo.update!()
          end

        _ ->
          Logger.warning("Car #{car.id}: could not derive efficiency — not enough charging data")
      end
    end)
  end

  # Counts pending Nominatim lookups for the imported cars (1 per missing address).
  defp count_geocoding_lookups(car_ids) do
    drive_lookups =
      Repo.one(
        from(d in Drive,
          where:
            d.car_id in ^car_ids and
              (is_nil(d.start_address_id) or is_nil(d.end_address_id)) and
              not is_nil(d.start_position_id) and not is_nil(d.end_position_id),
          select:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IS NULL THEN 1 ELSE 0 END), 0) + COALESCE(SUM(CASE WHEN ? IS NULL THEN 1 ELSE 0 END), 0)",
              d.start_address_id,
              d.end_address_id
            )
        )
      ) || 0

    charge_lookups =
      Repo.aggregate(
        from(c in ChargingProcess,
          where: c.car_id in ^car_ids and is_nil(c.address_id) and not is_nil(c.position_id)
        ),
        :count
      ) || 0

    drive_lookups + charge_lookups
  end

  defp finalize(state) do
    car_ids = Enum.map(state.car_mapping, fn {_tl_id, car} -> car.id end)

    # Count geocoding lookups needed before triggering repair
    geocoding_lookups = count_geocoding_lookups(car_ids)
    Logger.info("Geocoding: #{geocoding_lookups} reverse lookups needed")
    state = update_status(state, &Status.set_geocoding_lookups(&1, geocoding_lookups))

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

    # Recalculate car efficiency from imported charging data
    recalculate_car_efficiencies(state)

    write_import_metadata(state)

    # Complete
    state = update_status(state, &Status.set_state(&1, :complete))
    Logger.info("TeslaLogger import complete!")
    state
  end

  # Records one import_metadata row per car so a later run (or support request)
  # can tell when and from where data was imported.
  defp write_import_metadata(state) do
    imported_at = DateTime.utc_now()

    config = %{
      "host" => state.config[:host],
      "port" => state.config[:port],
      "database" => state.config[:database],
      "timezone" => state.config[:timezone],
      "import_mode" => to_string(state.status.import_mode)
    }

    Enum.each(state.car_mapping, fn {tl_car_id, car} ->
      attrs = %{
        source: "teslalogger",
        imported_at: imported_at,
        car_id: car.id,
        source_car_id: tl_car_id,
        positions_count: Repo.aggregate(from(p in Position, where: p.car_id == ^car.id), :count),
        drives_count: Repo.aggregate(from(d in Drive, where: d.car_id == ^car.id), :count),
        charging_processes_count:
          Repo.aggregate(from(cp in ChargingProcess, where: cp.car_id == ^car.id), :count),
        charges_count:
          Repo.aggregate(
            from(c in TeslaMate.Log.Charge,
              join: cp in assoc(c, :charging_process),
              where: cp.car_id == ^car.id
            ),
            :count
          ),
        states_count:
          Repo.aggregate(from(s in TeslaMate.Log.State, where: s.car_id == ^car.id), :count),
        updates_count:
          Repo.aggregate(from(u in TeslaMate.Log.Update, where: u.car_id == ^car.id), :count),
        warnings_count: length(state.status.warnings),
        config: config
      }

      case %ImportMetadata{} |> ImportMetadata.changeset(attrs) |> Repo.insert() do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.warning("Failed to write import metadata: #{inspect(changeset.errors)}")
      end
    end)
  end

  defp run_post_import_validation(state) do
    Enum.reduce(state.car_mapping, state, fn {_tl_id, car}, state ->
      # Count positions without drive_id
      orphan_positions =
        Repo.aggregate(
          from(p in Position, where: p.car_id == ^car.id and is_nil(p.drive_id)),
          :count
        )

      if orphan_positions > 0 do
        update_status(
          state,
          &Status.add_warning(
            &1,
            "Car #{car.id}: #{orphan_positions} positions without drive assignment"
          )
        )
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
