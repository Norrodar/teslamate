defmodule TeslaMate.Import.TeslaLogger.MysqlReader do
  @moduledoc false

  @doc """
  Connects to the TeslaLogger MySQL database.
  Returns {:ok, pid} or {:error, reason}.
  """
  def connect(config) do
    MyXQL.start_link(
      hostname: config[:host],
      port: config[:port],
      username: config[:username],
      password: config[:password],
      database: config[:database]
    )
  end

  @required_tables ~w(cars pos drivestate charging chargingstate state car_version)

  @doc "Verifies that all required TeslaLogger tables are present in the database."
  def check_schema(conn) do
    case MyXQL.query(conn, "SHOW TABLES") do
      {:ok, %MyXQL.Result{rows: rows}} ->
        existing = rows |> List.flatten() |> MapSet.new()
        missing = Enum.reject(@required_tables, &MapSet.member?(existing, &1))

        case missing do
          [] -> :ok
          _ -> {:error, "Missing required tables: #{Enum.join(missing, ", ")}"}
        end

      {:error, reason} ->
        {:error, "Failed to list tables: #{inspect(reason)}"}
    end
  end

  @doc """
  Reads car info and per-car data stats (drive count, charge count, position count,
  date range of first/last drive). Returns {:ok, car_info_list} or {:error, reason}.
  """
  def read_source_info(conn) do
    with :ok <- check_has_cars(conn),
         :ok <- check_has_data(conn),
         {:ok, cars} <- read_car_info(conn) do
      cars_with_stats =
        Enum.map(cars, fn car ->
          stats = read_car_stats(conn, car["id"])
          Map.merge(car, stats)
        end)

      {:ok, cars_with_stats}
    end
  end

  defp read_car_info(conn) do
    case MyXQL.query(conn, "SELECT id, vin, display_name FROM cars") do
      {:ok, %MyXQL.Result{rows: rows, columns: columns}} ->
        {:ok, rows_to_maps(columns, rows)}

      {:error, reason} ->
        {:error, "Failed to read car info: #{inspect(reason)}"}
    end
  end

  defp read_car_stats(conn, car_id) do
    drive_stats =
      case MyXQL.query(
             conn,
             "SELECT COUNT(*), MIN(StartDate), MAX(EndDate) FROM drivestate WHERE CarID = ?",
             [car_id]
           ) do
        {:ok, %MyXQL.Result{rows: [[count, min_date, max_date]]}} ->
          %{"drive_count" => count || 0, "data_from" => min_date, "data_to" => max_date}

        _ ->
          %{"drive_count" => 0, "data_from" => nil, "data_to" => nil}
      end

    charge_count =
      case MyXQL.query(conn, "SELECT COUNT(*) FROM chargingstate WHERE CarID = ?", [car_id]) do
        {:ok, %MyXQL.Result{rows: [[count]]}} -> count || 0
        _ -> 0
      end

    pos_count =
      case MyXQL.query(conn, "SELECT COUNT(*) FROM pos WHERE CarID = ?", [car_id]) do
        {:ok, %MyXQL.Result{rows: [[count]]}} -> count || 0
        _ -> 0
      end

    Map.merge(drive_stats, %{"charge_count" => charge_count, "pos_count" => pos_count})
  end

  defp check_has_cars(conn) do
    case MyXQL.query(conn, "SELECT COUNT(*) FROM cars") do
      {:ok, %MyXQL.Result{rows: [[0]]}} ->
        {:error, "No cars found in TeslaLogger database"}

      {:ok, %MyXQL.Result{rows: [[_count]]}} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to query cars table: #{inspect(reason)}"}
    end
  end

  defp check_has_data(conn) do
    case MyXQL.query(conn, "SELECT COUNT(*) FROM pos LIMIT 1") do
      {:ok, %MyXQL.Result{rows: [[0]]}} ->
        {:error, "No position data found in TeslaLogger database"}

      {:ok, %MyXQL.Result{rows: [[_count]]}} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to query pos table: #{inspect(reason)}"}
    end
  end

  @doc "Reads all cars from TeslaLogger."
  def read_cars(conn) do
    case MyXQL.query(conn, "SELECT id, vin, display_name, tasker_hash, model_name FROM cars") do
      {:ok, %MyXQL.Result{rows: rows, columns: columns}} ->
        {:ok, rows_to_maps(columns, rows)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Reads positions for a given car, ordered by timestamp."
  def read_positions(conn, car_id) do
    query = """
    SELECT id, Datum, lat, lng, speed, power, odometer, altitude,
           battery_level, inside_temp, outside_temp,
           battery_heater, battery_range_km, ideal_battery_range_km
    FROM pos
    WHERE CarID = ?
    ORDER BY Datum ASC
    """

    fetch_all(conn, query, [car_id])
  end

  @doc "Counts positions for a given car."
  def count_positions(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM pos WHERE CarID = ?", [car_id])
  end

  @doc "Reads drives for a given car, ordered by start date."
  def read_drives(conn, car_id) do
    query = """
    SELECT id, StartDate, EndDate, StartPos, EndPos,
           outside_temp_avg, speed_max, power_max, power_min
    FROM drivestate
    WHERE CarID = ?
    ORDER BY StartDate ASC
    """

    fetch_all(conn, query, [car_id])
  end

  @doc "Counts drives for a given car."
  def count_drives(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM drivestate WHERE CarID = ?", [car_id])
  end

  @doc "Reads the N most recent drives for a car, newest first. Same columns as read_drives."
  def read_recent_drives(conn, car_id, limit) do
    query = """
    SELECT id, StartDate, EndDate, StartPos, EndPos,
           outside_temp_avg, speed_max, power_max, power_min
    FROM drivestate
    WHERE CarID = ?
    ORDER BY StartDate DESC
    LIMIT #{limit}
    """

    fetch_all(conn, query, [car_id])
  end

  @doc "Reads full position rows for the given pos IDs, ordered by timestamp."
  def read_positions_by_ids(_conn, []), do: {:ok, []}

  def read_positions_by_ids(conn, ids) do
    placeholders = ids |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")

    query = """
    SELECT id, Datum, lat, lng, speed, power, odometer, altitude,
           battery_level, inside_temp, outside_temp,
           battery_heater, battery_range_km, ideal_battery_range_km
    FROM pos
    WHERE id IN (#{placeholders})
    ORDER BY Datum ASC
    """

    fetch_all(conn, query, ids)
  end

  @doc "Reads charge data points for a given car, ordered by timestamp."
  def read_charges(conn, car_id) do
    # Use a correlated subquery to guarantee at most one chargingstate match per
    # charging row. Without this, overlapping chargingstate time ranges would cause
    # the LEFT JOIN to produce duplicate rows. We pick the longest (most specific)
    # session when there is ambiguity at boundaries.
    query = """
    SELECT c.id, c.Datum, c.battery_level,
           c.charge_energy_added,
           c.charger_power, c.ideal_battery_range_km,
           c.battery_range_km,
           c.charger_voltage,
           c.charger_phases, c.charger_actual_current, c.outside_temp,
           c.charger_pilot_current, c.battery_heater,
           cs.id AS chargingstate_id,
           cs.fast_charger_brand, cs.fast_charger_type,
           cs.conn_charge_cable, cs.max_charger_power
    FROM charging c
    LEFT JOIN chargingstate cs ON cs.id = (
      SELECT cs2.id FROM chargingstate cs2
      WHERE cs2.CarID = c.CarID
        AND c.Datum BETWEEN cs2.StartDate AND cs2.EndDate
      ORDER BY TIMESTAMPDIFF(SECOND, cs2.StartDate, cs2.EndDate) DESC
      LIMIT 1
    )
    WHERE c.CarID = ?
    ORDER BY c.Datum ASC
    """

    fetch_all(conn, query, [car_id])
  end

  @doc "Counts charges for a given car."
  def count_charges(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM charging WHERE CarID = ?", [car_id])
  end

  @doc "Reads charging sessions for a given car, ordered by start date."
  def read_charging_sessions(conn, car_id) do
    query = """
    SELECT id, StartDate, EndDate, charge_energy_added, cost_total,
           cost_per_kwh, cost_per_session, cost_per_minute,
           fast_charger_brand, fast_charger_type,
           conn_charge_cable, max_charger_power,
           cost_kwh_meter_invoice
    FROM chargingstate
    WHERE CarID = ?
    ORDER BY StartDate ASC
    """

    fetch_all(conn, query, [car_id])
  end

  @doc "Counts charging sessions for a given car."
  def count_charging_sessions(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM chargingstate WHERE CarID = ?", [car_id])
  end

  @doc "Reads the N most recent charging sessions, newest first. Same columns as read_charging_sessions."
  def read_recent_charging_sessions(conn, car_id, limit) do
    query = """
    SELECT id, StartDate, EndDate, charge_energy_added, cost_total,
           cost_per_kwh, cost_per_session, cost_per_minute,
           fast_charger_brand, fast_charger_type,
           conn_charge_cable, max_charger_power,
           cost_kwh_meter_invoice
    FROM chargingstate
    WHERE CarID = ?
    ORDER BY StartDate DESC
    LIMIT #{limit}
    """

    fetch_all(conn, query, [car_id])
  end

  @doc """
  Reads charge rows for one known session within its local-time range.
  Start/end are the raw StartDate/EndDate from chargingstate (local time).
  """
  def read_charges_in_range(conn, car_id, start_naive, end_naive) do
    query = """
    SELECT c.id, c.Datum, c.battery_level,
           c.charge_energy_added,
           c.charger_power, c.ideal_battery_range_km,
           c.battery_range_km,
           c.charger_voltage,
           c.charger_phases, c.charger_actual_current, c.outside_temp,
           c.charger_pilot_current, c.battery_heater
    FROM charging c
    WHERE c.CarID = ? AND c.Datum BETWEEN ? AND ?
    ORDER BY c.Datum ASC
    """

    fetch_all(conn, query, [car_id, start_naive, end_naive])
  end

  @doc "Reads vehicle states for a given car."
  def read_states(conn, car_id) do
    query = """
    SELECT id, StartDate, EndDate, state
    FROM state
    WHERE CarID = ?
    ORDER BY StartDate ASC
    """

    fetch_all(conn, query, [car_id])
  end

  @doc "Counts states for a given car."
  def count_states(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM state WHERE CarID = ?", [car_id])
  end

  @doc "Reads firmware updates for a given car."
  def read_updates(conn, car_id) do
    query = """
    SELECT id, StartDate, version
    FROM car_version
    WHERE CarID = ?
    ORDER BY StartDate ASC
    """

    fetch_all(conn, query, [car_id])
  end

  @doc "Counts updates for a given car."
  def count_updates(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM car_version WHERE CarID = ?", [car_id])
  end

  @doc "Reads TPMS data for a given car, pivoted by tire ID, ordered by timestamp."
  def read_tpms(conn, car_id) do
    query = """
    SELECT Datum,
           MAX(CASE WHEN TireId = 1 THEN Pressure END) AS tpms_fl,
           MAX(CASE WHEN TireId = 2 THEN Pressure END) AS tpms_fr,
           MAX(CASE WHEN TireId = 3 THEN Pressure END) AS tpms_rl,
           MAX(CASE WHEN TireId = 4 THEN Pressure END) AS tpms_rr
    FROM TPMS
    WHERE CarId = ?
    GROUP BY Datum
    ORDER BY Datum ASC
    """

    case fetch_all(conn, query, [car_id]) do
      {:ok, _} = result -> result
      {:error, %MyXQL.Error{mysql: %{code: 1146}}} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  ## Private

  defp fetch_all(conn, query, params) do
    case MyXQL.query(conn, query, params, timeout: :infinity) do
      {:ok, %MyXQL.Result{rows: rows, columns: columns}} ->
        {:ok, rows_to_maps(columns, rows)}

      {:error, _} = err ->
        err
    end
  end

  defp count_query(conn, query, params) do
    case MyXQL.query(conn, query, params) do
      {:ok, %MyXQL.Result{rows: [[count]]}} -> {:ok, count}
      {:error, _} = err -> err
    end
  end

  defp rows_to_maps(columns, rows) do
    Enum.map(rows, &row_to_map(columns, &1))
  end

  defp row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new()
  end
end
