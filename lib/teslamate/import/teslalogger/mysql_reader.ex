defmodule TeslaMate.Import.TeslaLogger.MysqlReader do
  @moduledoc false

  require Logger

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
           battery_level, inside_temp, outside_temp, battery_heater,
           battery_range_km, ideal_battery_range_km
    FROM pos
    WHERE CarID = ?
    ORDER BY Datum ASC
    """

    stream_query(conn, query, [car_id])
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

    stream_query(conn, query, [car_id])
  end

  @doc "Counts drives for a given car."
  def count_drives(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM drivestate WHERE CarID = ?", [car_id])
  end

  @doc "Reads charge data points for a given car, ordered by timestamp."
  def read_charges(conn, car_id) do
    query = """
    SELECT c.id, c.Datum, c.battery_level, c.usable_battery_level,
           c.charge_energy_added,
           c.charger_power, c.ideal_battery_range_km, c.rated_battery_range_km,
           c.charger_voltage,
           c.charger_phases, c.charger_actual_current, c.outside_temp,
           c.charger_pilot_current, c.battery_heater,
           cs.id AS chargingstate_id
    FROM charging c
    LEFT JOIN chargingstate cs ON c.Datum BETWEEN cs.StartDate AND cs.EndDate
      AND cs.CarID = c.CarID
    WHERE c.CarID = ?
    ORDER BY c.Datum ASC
    """

    stream_query(conn, query, [car_id])
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
           conn_charge_cable, max_charger_power
    FROM chargingstate
    WHERE CarID = ?
    ORDER BY StartDate ASC
    """

    stream_query(conn, query, [car_id])
  end

  @doc "Counts charging sessions for a given car."
  def count_charging_sessions(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM chargingstate WHERE CarID = ?", [car_id])
  end

  @doc "Reads vehicle states for a given car."
  def read_states(conn, car_id) do
    query = """
    SELECT id, StartDate, EndDate, state
    FROM state
    WHERE CarID = ?
    ORDER BY StartDate ASC
    """

    stream_query(conn, query, [car_id])
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

    stream_query(conn, query, [car_id])
  end

  @doc "Counts updates for a given car."
  def count_updates(conn, car_id) do
    count_query(conn, "SELECT COUNT(*) FROM car_version WHERE CarID = ?", [car_id])
  end

  @doc "Reads the position row for a given TeslaLogger pos ID."
  def read_position_by_id(conn, pos_id) do
    query = "SELECT lat, lng, Datum FROM pos WHERE id = ? LIMIT 1"

    case MyXQL.query(conn, query, [pos_id]) do
      {:ok, %MyXQL.Result{rows: [row], columns: columns}} ->
        {:ok, row_to_map(columns, row)}

      {:ok, %MyXQL.Result{rows: []}} ->
        {:ok, nil}

      {:error, _} = err ->
        err
    end
  end

  ## Private

  defp stream_query(conn, query, params) do
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
