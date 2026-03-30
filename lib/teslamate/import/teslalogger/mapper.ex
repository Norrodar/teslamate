defmodule TeslaMate.Import.TeslaLogger.Mapper do
  @moduledoc false

  require Logger

  @doc "Maps a TeslaLogger pos row to TeslaMate position attrs."
  def map_position(row, timezone) do
    %{
      date: to_utc(row["Datum"], timezone),
      latitude: to_decimal(row["lat"]),
      longitude: to_decimal(row["lng"]),
      speed: to_integer(row["speed"]),
      power: to_integer(row["power"]),
      odometer: to_float(row["odometer"]),
      elevation: to_integer(row["altitude"]),
      battery_level: to_integer(row["battery_level"]),
      inside_temp: to_decimal(row["inside_temp"]),
      outside_temp: to_decimal(row["outside_temp"]),
      battery_heater: to_boolean(row["battery_heater"]),
      ideal_battery_range_km: to_decimal(row["ideal_battery_range_km"] || row["battery_range_km"]),
      rated_battery_range_km: to_decimal(row["battery_range_km"])
    }
  end

  @doc "Maps a TeslaLogger drivestate row to TeslaMate drive attrs."
  def map_drive(row, timezone) do
    %{
      start_date: to_utc(row["StartDate"], timezone),
      end_date: to_utc(row["EndDate"], timezone),
      outside_temp_avg: to_decimal(row["outside_temp_avg"]),
      speed_max: to_integer(row["speed_max"]),
      power_max: to_integer(row["power_max"]),
      power_min: to_integer(row["power_min"])
    }
  end

  @doc """
  Enriches drive attrs with data derived from its positions.
  `positions` should be the list of position attrs within this drive's time range.
  """
  def enrich_drive(drive_attrs, positions) when is_list(positions) do
    case positions do
      [] ->
        drive_attrs

      [first | _] = all ->
        last = List.last(all)

        inside_temps =
          all
          |> Enum.map(& &1.inside_temp)
          |> Enum.reject(&is_nil/1)

        inside_temp_avg =
          case inside_temps do
            [] -> nil
            temps -> Decimal.div(Enum.reduce(temps, Decimal.new(0), &Decimal.add/2), Decimal.new(length(temps)))
          end

        Map.merge(drive_attrs, %{
          start_km: first.odometer,
          end_km: last.odometer,
          distance: distance(first.odometer, last.odometer),
          duration_min: duration_minutes(drive_attrs.start_date, drive_attrs.end_date),
          start_ideal_range_km: first.ideal_battery_range_km,
          end_ideal_range_km: last.ideal_battery_range_km,
          start_rated_range_km: first.rated_battery_range_km,
          end_rated_range_km: last.rated_battery_range_km,
          inside_temp_avg: inside_temp_avg
        })
    end
  end

  @doc "Maps a TeslaLogger charging row to TeslaMate charge attrs."
  def map_charge(row, timezone) do
    %{
      date: to_utc(row["Datum"], timezone),
      battery_level: to_integer(row["battery_level"]),
      usable_battery_level: to_integer(row["usable_battery_level"]),
      charge_energy_added: to_decimal(row["charge_energy_added"]),
      charger_power: to_integer(row["charger_power"]),
      ideal_battery_range_km: to_decimal(row["ideal_battery_range_km"]),
      rated_battery_range_km: to_decimal(row["rated_battery_range_km"]),
      charger_voltage: to_integer(row["charger_voltage"]),
      charger_phases: to_integer(row["charger_phases"]),
      charger_actual_current: to_integer(row["charger_actual_current"]),
      outside_temp: to_decimal(row["outside_temp"]),
      charger_pilot_current: to_integer(row["charger_pilot_current"]),
      battery_heater: to_boolean(row["battery_heater"])
    }
  end

  @doc "Maps a TeslaLogger chargingstate row to TeslaMate charging_process attrs."
  def map_charging_process(row, timezone) do
    %{
      start_date: to_utc(row["StartDate"], timezone),
      end_date: to_utc(row["EndDate"], timezone),
      charge_energy_added: to_decimal(row["charge_energy_added"]),
      cost: to_decimal(row["cost_total"]),
      duration_min: duration_minutes(
        to_utc(row["StartDate"], timezone),
        to_utc(row["EndDate"], timezone)
      )
    }
  end

  @doc """
  Enriches charging_process attrs with data derived from its charges.
  """
  def enrich_charging_process(cp_attrs, charges) when is_list(charges) do
    case charges do
      [] ->
        cp_attrs

      [first | _] = all ->
        last = List.last(all)

        outside_temps =
          all
          |> Enum.map(& &1.outside_temp)
          |> Enum.reject(&is_nil/1)

        outside_temp_avg =
          case outside_temps do
            [] -> nil
            temps -> Decimal.div(Enum.reduce(temps, Decimal.new(0), &Decimal.add/2), Decimal.new(length(temps)))
          end

        Map.merge(cp_attrs, %{
          start_battery_level: first.battery_level,
          end_battery_level: last.battery_level,
          start_ideal_range_km: first.ideal_battery_range_km,
          end_ideal_range_km: last.ideal_battery_range_km,
          outside_temp_avg: outside_temp_avg
        })
    end
  end

  @doc "Maps a TeslaLogger car_version row to TeslaMate update attrs."
  def map_update(row, timezone) do
    %{
      start_date: to_utc(row["StartDate"], timezone),
      version: row["version"]
    }
  end

  @doc """
  Adds end_date to updates based on the next update's start_date.
  """
  def add_update_end_dates(updates) do
    updates
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.map(fn
      [current, nil] -> current
      [current, next] -> Map.put(current, :end_date, next.start_date)
    end)
  end

  @doc "Maps a TeslaLogger state row to TeslaMate state attrs."
  def map_state(row, timezone) do
    %{
      start_date: to_utc(row["StartDate"], timezone),
      end_date: to_utc(row["EndDate"], timezone),
      state: map_state_value(row["state"])
    }
  end

  ## Private

  defp map_state_value(state) when is_binary(state) do
    case String.downcase(state) do
      "online" -> :online
      "offline" -> :offline
      "asleep" -> :asleep
      "sleeping" -> :asleep
      "suspended" -> :asleep
      "start" -> :online
      "driving" -> :online
      "charging" -> :online
      _ -> :online
    end
  end

  defp map_state_value(_), do: :online

  defp to_utc(nil, _timezone), do: nil

  defp to_utc(%NaiveDateTime{} = ndt, timezone) do
    case DateTime.from_naive(ndt, timezone) do
      {:ok, dt} ->
        case DateTime.shift_zone(dt, "Etc/UTC") do
          {:ok, utc} -> DateTime.truncate(utc, :microsecond)
          {:error, _} -> DateTime.truncate(dt, :microsecond)
        end

      {:ambiguous, dt, _} ->
        Logger.debug("Ambiguous time during DST transition: #{ndt} in #{timezone}, using first")
        case DateTime.shift_zone(dt, "Etc/UTC") do
          {:ok, utc} -> DateTime.truncate(utc, :microsecond)
          {:error, _} -> DateTime.truncate(dt, :microsecond)
        end

      {:gap, _, dt} ->
        Logger.debug("Gap time during DST transition: #{ndt} in #{timezone}, using after")
        case DateTime.shift_zone(dt, "Etc/UTC") do
          {:ok, utc} -> DateTime.truncate(utc, :microsecond)
          {:error, _} -> DateTime.truncate(dt, :microsecond)
        end

      {:error, reason} ->
        Logger.warning("Failed to convert #{ndt} in timezone #{timezone}: #{inspect(reason)}")
        nil
    end
  end

  defp to_utc(%DateTime{} = dt, _timezone) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc} -> DateTime.truncate(utc, :microsecond)
      {:error, _} -> DateTime.truncate(dt, :microsecond)
    end
  end

  defp to_utc(_, _timezone), do: nil

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(val) when is_float(val), do: Decimal.from_float(val)
  defp to_decimal(val) when is_integer(val), do: Decimal.new(val)

  defp to_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp to_decimal(_), do: nil

  defp to_integer(nil), do: nil
  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(val) when is_float(val), do: round(val)

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp to_integer(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp to_integer(_), do: nil

  defp to_float(nil), do: nil
  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val / 1
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)

  defp to_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp to_float(_), do: nil

  defp to_boolean(nil), do: nil
  defp to_boolean(true), do: true
  defp to_boolean(false), do: false
  defp to_boolean(1), do: true
  defp to_boolean(0), do: false

  defp to_boolean(val) when is_binary(val) do
    case String.downcase(val) do
      "1" -> true
      "true" -> true
      "0" -> false
      "false" -> false
      _ -> nil
    end
  end

  defp to_boolean(_), do: nil

  defp distance(nil, _), do: nil
  defp distance(_, nil), do: nil
  defp distance(start_km, end_km), do: Float.round(end_km - start_km, 2)

  defp duration_minutes(nil, _), do: nil
  defp duration_minutes(_, nil), do: nil

  defp duration_minutes(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    DateTime.diff(end_dt, start_dt, :second) |> div(60)
  end
end
