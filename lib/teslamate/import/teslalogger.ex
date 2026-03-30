defmodule TeslaMate.Import.TeslaLogger do
  @moduledoc false

  use GenServer

  require Logger

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
  def run(car_mapping \\ %{}), do: GenServer.call(@name, {:run, car_mapping}, :infinity)
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

  def handle_call({:run, car_mapping}, _from, state) do
    state = %{state | car_mapping: car_mapping}
    send(self(), :start_import)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:start_import, state) do
    parent = self()

    Task.start_link(fn ->
      result_state = do_import(state)
      send(parent, {:import_done, result_state})
    end)

    {:noreply, state}
  end

  def handle_info({:import_done, result_state}, _state) do
    {:noreply, result_state}
  end

  ## Import Orchestration

  defp do_import(state) do
    state
    |> update_status(&Status.set_state(&1, :connecting))
    |> connect_mysql()
    |> case do
      {:error, reason, state} ->
        update_status(state, &Status.set_state(&1, {:error, "MySQL connection failed: #{inspect(reason)}"}))

      {:ok, state} ->
        state
        |> update_status(&Status.set_state(&1, :running))
        |> import_cars()
        |> import_all_car_data()
        |> finalize()
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
    state = update_status(state, &Status.start_step(&1, :cars))
    conn = state.mysql_conn

    case MysqlReader.read_cars(conn) do
      {:ok, tl_cars} ->
        Logger.info("Found #{length(tl_cars)} car(s) in TeslaLogger")
        state = update_status(state, fn s -> %{s | car_count: length(tl_cars)} end)

        car_mapping =
          Enum.reduce(tl_cars, %{}, fn tl_car, acc ->
            tl_car_id = tl_car["id"]

            case create_or_find_car(tl_car, state.car_mapping) do
              {:ok, car} ->
                Logger.info("Mapped TeslaLogger car #{tl_car_id} -> TeslaMate car #{car.id} (#{car.name || car.vin})")
                Map.put(acc, tl_car_id, car)

              {:error, reason} ->
                Logger.warning("Failed to create car for TeslaLogger car #{tl_car_id}: #{inspect(reason)}")
                acc
            end
          end)

        state = %{state | car_mapping: car_mapping}
        update_status(state, &Status.complete_step(&1, :cars))

      {:error, reason} ->
        Logger.error("Failed to read cars: #{inspect(reason)}")
        update_status(state, &Status.fail_step(&1, :cars, inspect(reason)))
    end
  end

  defp import_all_car_data(state) do
    Enum.reduce(state.car_mapping, state, fn {tl_car_id, car}, state ->
      Logger.info("Importing data for car #{car.id} (TeslaLogger ID: #{tl_car_id})")
      timezone = state.config[:timezone]

      state
      |> import_positions(tl_car_id, car.id, timezone)
      |> import_drives(tl_car_id, car.id, timezone)
      |> import_charging_data(tl_car_id, car.id, timezone)
      |> import_states(tl_car_id, car.id, timezone)
      |> import_updates(tl_car_id, car.id, timezone)
    end)
  end

  defp import_positions(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    with {:ok, total} <- MysqlReader.count_positions(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :positions, total)),
         {:ok, rows} <- MysqlReader.read_positions(conn, tl_car_id) do

      mapped =
        Enum.map(rows, &Mapper.map_position(&1, timezone))

      {valid, errors} = Validator.validate_positions(mapped)
      warnings = Validator.format_warnings(errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      progress_fn = fn imported, _total ->
        broadcast(update_status(state, &Status.update_step_progress(&1, :positions, imported)).status)
      end

      state =
        case Writer.insert_positions(car_id, valid, progress_fn) do
          {:ok, new_date_map} ->
            %{state | date_to_pos_id: Map.merge(state.date_to_pos_id, new_date_map)}

          {:error, reason} ->
            Logger.error("Position insert failed: #{inspect(reason)}")
            state
        end

      update_status(state, &Status.complete_step(&1, :positions))
    else
      {:error, reason} ->
        Logger.error("Failed to import positions: #{inspect(reason)}")
        update_status(state, &Status.fail_step(&1, :positions, inspect(reason)))
    end
  end

  defp import_drives(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    with {:ok, total} <- MysqlReader.count_drives(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :drives, total)),
         {:ok, rows} <- MysqlReader.read_drives(conn, tl_car_id) do

      mapped =
        Enum.map(rows, fn row ->
          drive_attrs = Mapper.map_drive(row, timezone)

          # Find positions within this drive's time range
          drive_positions =
            state.date_to_pos_id
            |> Map.keys()
            |> Enum.filter(fn date ->
              DateTime.compare(date, drive_attrs.start_date) != :lt and
                (drive_attrs.end_date == nil or DateTime.compare(date, drive_attrs.end_date) != :gt)
            end)
            |> Enum.sort()

          # We need the actual position data for enrichment, query from DB
          pos_attrs = get_position_attrs_for_dates(drive_positions, state.date_to_pos_id)
          Mapper.enrich_drive(drive_attrs, pos_attrs)
        end)

      {valid, errors} = Validator.validate_drives(mapped)
      warnings = Validator.format_warnings(errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      case Writer.insert_drives(car_id, valid) do
        {:ok, drives_with_ids} ->
          Writer.associate_positions_with_drives(drives_with_ids, state.date_to_pos_id)

        {:error, reason} ->
          Logger.error("Drive insert failed: #{inspect(reason)}")
      end

      update_status(state, &Status.complete_step(&1, :drives))
    else
      {:error, reason} ->
        Logger.error("Failed to import drives: #{inspect(reason)}")
        update_status(state, &Status.fail_step(&1, :drives, inspect(reason)))
    end
  end

  defp import_charging_data(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    # First: import charging_processes
    with {:ok, cp_total} <- MysqlReader.count_charging_sessions(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :charging_processes, cp_total)),
         {:ok, cp_rows} <- MysqlReader.read_charging_sessions(conn, tl_car_id),
         {:ok, c_total} <- MysqlReader.count_charges(conn, tl_car_id),
         {:ok, c_rows} <- MysqlReader.read_charges(conn, tl_car_id) do

      # Map charges first (need them for enriching charging_processes)
      mapped_charges =
        Enum.map(c_rows, fn row ->
          charge = Mapper.map_charge(row, timezone)
          Map.put(charge, :tl_chargingstate_id, row["chargingstate_id"])
        end)

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

      tl_cs_id_to_cp_id =
        case Writer.insert_charging_processes(car_id, valid_cps_with_tl_ids, state.date_to_pos_id) do
          {:ok, mapping} -> mapping
          {:error, reason} ->
            Logger.error("Charging process insert failed: #{inspect(reason)}")
            %{}
        end

      state = update_status(state, &Status.complete_step(&1, :charging_processes))

      # Now import charges
      state = update_status(state, &Status.start_step(&1, :charges, c_total))

      {valid_charges, c_errors} = Validator.validate_charges(mapped_charges)
      warnings = Validator.format_warnings(c_errors)
      state = update_status(state, &Status.add_warnings(&1, warnings))

      progress_fn = fn imported, _total ->
        broadcast(update_status(state, &Status.update_step_progress(&1, :charges, imported)).status)
      end

      case Writer.insert_charges(valid_charges, tl_cs_id_to_cp_id, progress_fn) do
        {:ok, _count} -> :ok
        {:error, reason} -> Logger.error("Charge insert failed: #{inspect(reason)}")
      end

      update_status(state, &Status.complete_step(&1, :charges))
    else
      {:error, reason} ->
        Logger.error("Failed to import charging data: #{inspect(reason)}")
        state
        |> update_status(&Status.fail_step(&1, :charging_processes, inspect(reason)))
        |> update_status(&Status.fail_step(&1, :charges, inspect(reason)))
    end
  end

  defp import_states(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    with {:ok, total} <- MysqlReader.count_states(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :states, total)),
         {:ok, rows} <- MysqlReader.read_states(conn, tl_car_id) do

      mapped = Enum.map(rows, &Mapper.map_state(&1, timezone))

      # Filter out invalid states
      valid = Enum.filter(mapped, &(&1.state != nil and &1.start_date != nil))

      case Writer.insert_states(car_id, valid) do
        {:ok, count} ->
          Logger.info("Inserted #{count} states for car #{car_id}")

        {:error, reason} ->
          Logger.error("State insert failed: #{inspect(reason)}")
      end

      update_status(state, &Status.complete_step(&1, :states))
    else
      {:error, reason} ->
        Logger.error("Failed to import states: #{inspect(reason)}")
        update_status(state, &Status.fail_step(&1, :states, inspect(reason)))
    end
  end

  defp import_updates(state, tl_car_id, car_id, timezone) do
    conn = state.mysql_conn

    with {:ok, total} <- MysqlReader.count_updates(conn, tl_car_id),
         state = update_status(state, &Status.start_step(&1, :updates, total)),
         {:ok, rows} <- MysqlReader.read_updates(conn, tl_car_id) do

      mapped =
        rows
        |> Enum.map(&Mapper.map_update(&1, timezone))
        |> Mapper.add_update_end_dates()

      case Writer.insert_updates(car_id, mapped) do
        {:ok, count} ->
          Logger.info("Inserted #{count} updates for car #{car_id}")

        {:error, reason} ->
          Logger.error("Update insert failed: #{inspect(reason)}")
      end

      update_status(state, &Status.complete_step(&1, :updates))
    else
      {:error, reason} ->
        Logger.error("Failed to import updates: #{inspect(reason)}")
        update_status(state, &Status.fail_step(&1, :updates, inspect(reason)))
    end
  end

  defp finalize(state) do
    # Trigger geocoding
    state = update_status(state, &Status.start_step(&1, :geocoding))
    :ok = Repair.trigger_run()
    state = update_status(state, &Status.complete_step(&1, :geocoding))

    # Run post-import validation
    state = update_status(state, &Status.start_step(&1, :validation))
    state = run_post_import_validation(state)
    state = update_status(state, &Status.complete_step(&1, :validation))

    # Complete
    state = update_status(state, &Status.set_state(&1, :complete))
    Logger.info("TeslaLogger import complete!")
    state
  end

  defp run_post_import_validation(state) do
    import Ecto.Query

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
    vin = tl_car["vin"]
    display_name = tl_car["display_name"]

    # Check if user provided mapping for this car
    user_car_info = Map.get(user_mapping, tl_car_id, %{})

    vin = user_car_info[:vin] || vin
    eid = user_car_info[:eid] || tl_car_id * 1000
    vid = user_car_info[:vid] || tl_car_id * 1000 + 1

    # Try to find existing car by VIN
    case vin do
      nil ->
        create_import_car(eid, vid, "TeslaLogger_#{tl_car_id}", display_name)

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

        car.settings
        |> CarSettings.changeset(%{
          suspend_min: 0,
          suspend_after_idle_min: 99999,
          use_streaming_api: false,
          enabled: false
        })
        |> Repo.update()

        {:ok, car}

      {:error, _} = err ->
        err
    end
  end

  ## Helpers

  defp get_position_attrs_for_dates(dates, date_to_pos_id) do
    import Ecto.Query

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

  defp update_status(state, fun) do
    new_status = fun.(state.status)
    broadcast(new_status)
    %{state | status: new_status}
  end

  defp broadcast(status) do
    Phoenix.PubSub.broadcast(TeslaMate.PubSub, @topic, {:teslalogger_import, status})
  end
end
