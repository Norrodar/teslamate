defmodule TeslaMate.Import.TeslaLogger.Mapper do
  @moduledoc false

  require Logger

  @doc "Maps a TeslaLogger pos row to TeslaMate position attrs."
  def map_position(row, timezone) do
    {lat, lng} = sanitize_coords(row["lat"], row["lng"])

    %{
      date: to_utc(row["Datum"], timezone),
      latitude: to_decimal(lat),
      longitude: to_decimal(lng),
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

  @doc """
  Merges TPMS data into mapped positions. Both lists must be sorted by date ASC.
  Each position gets the most recent TPMS reading at or before its timestamp.
  TPMS pressures are in bar (TeslaLogger stores bar).
  """
  def merge_tpms(positions, []), do: positions

  def merge_tpms(positions, tpms_rows) do
    # Convert TPMS rows to sorted list of {unix_seconds, pressures_map}
    tpms_sorted =
      tpms_rows
      |> Enum.map(fn row ->
        # Datum from MySQL is already a DateTime or NaiveDateTime
        unix = datetime_to_unix(row["Datum"])

        pressures = %{
          tpms_pressure_fl: to_decimal(row["tpms_fl"]),
          tpms_pressure_fr: to_decimal(row["tpms_fr"]),
          tpms_pressure_rl: to_decimal(row["tpms_rl"]),
          tpms_pressure_rr: to_decimal(row["tpms_rr"])
        }

        {unix, pressures}
      end)
      |> Enum.reject(fn {unix, _} -> unix == nil end)

    # Merge: walk both sorted lists in O(n+m)
    do_merge_tpms(positions, tpms_sorted, nil)
  end

  defp do_merge_tpms([], _tpms, _current), do: []

  defp do_merge_tpms([pos | rest_pos], tpms, current_pressures) do
    pos_unix = datetime_to_unix(pos.date)

    # Advance TPMS cursor to find the latest reading <= pos timestamp
    {new_current, remaining_tpms} = advance_tpms(tpms, pos_unix, current_pressures)

    enriched =
      if new_current do
        Map.merge(pos, new_current)
      else
        pos
      end

    [enriched | do_merge_tpms(rest_pos, remaining_tpms, new_current)]
  end

  defp advance_tpms([{tpms_unix, pressures} | rest], pos_unix, _current)
       when tpms_unix <= pos_unix do
    advance_tpms(rest, pos_unix, pressures)
  end

  defp advance_tpms(tpms, _pos_unix, current), do: {current, tpms}

  defp datetime_to_unix(nil), do: nil
  defp datetime_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :second)

  defp datetime_to_unix(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:second)
  end

  defp datetime_to_unix(_), do: nil

  @doc "Maps a TeslaLogger drivestate row to TeslaMate drive attrs."
  def map_drive(row, timezone) do
    start_date = to_utc(row["StartDate"], timezone)
    end_date = to_utc(row["EndDate"], timezone)
    end_date = ensure_end_after_start(start_date, end_date)

    %{
      start_date: start_date,
      end_date: end_date,
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

        inside_temp_avg = decimal_avg(all, & &1.inside_temp)

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
    dc? = is_dc_charger?(row)

    %{
      date: to_utc(row["Datum"], timezone),
      battery_level: to_integer(row["battery_level"]),
      charge_energy_added: to_decimal(row["charge_energy_added"]),
      charger_power: to_integer(row["charger_power"]),
      ideal_battery_range_km: to_decimal(row["ideal_battery_range_km"]),
      rated_battery_range_km: to_decimal(row["battery_range_km"]),
      charger_voltage: to_integer(row["charger_voltage"]),
      charger_phases: if(dc?, do: nil, else: clamp_phases(to_integer(row["charger_phases"]))),
      charger_actual_current: to_integer(row["charger_actual_current"]),
      outside_temp: to_decimal(row["outside_temp"]),
      charger_pilot_current: to_integer(row["charger_pilot_current"]),
      battery_heater: to_boolean(row["battery_heater"]),
      fast_charger_present: dc?,
      fast_charger_brand: if(dc?, do: non_empty_string(row["fast_charger_brand"])),
      fast_charger_type: if(dc?, do: non_empty_string(row["fast_charger_type"])),
      conn_charge_cable: non_empty_string(row["conn_charge_cable"])
    }
  end

  @doc "Maps a TeslaLogger chargingstate row to TeslaMate charging_process attrs."
  def map_charging_process(row, timezone) do
    start_date = to_utc(row["StartDate"], timezone)
    end_date = to_utc(row["EndDate"], timezone)
    end_date = ensure_end_after_start(start_date, end_date)

    %{
      start_date: start_date,
      end_date: end_date,
      charge_energy_added: to_decimal(row["charge_energy_added"]),
      cost: to_decimal(row["cost_total"]),
      duration_min: duration_minutes(start_date, end_date)
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

        outside_temp_avg = decimal_avg(all, & &1.outside_temp)
        energy_used = calculate_energy_used(all)

        Map.merge(cp_attrs, %{
          start_battery_level: first.battery_level,
          end_battery_level: last.battery_level,
          start_ideal_range_km: first.ideal_battery_range_km,
          end_ideal_range_km: last.ideal_battery_range_km,
          start_rated_range_km: first.rated_battery_range_km,
          end_rated_range_km: last.rated_battery_range_km,
          outside_temp_avg: outside_temp_avg,
          charge_energy_used: energy_used
        })
    end
  end

  # Calculates energy used (kWh) from charge rows, same logic as TeslaMate's
  # Log.calculate_energy_used: power * time_delta for each consecutive pair.
  defp calculate_energy_used(charges) when length(charges) < 2, do: nil

  defp calculate_energy_used(charges) do
    charges
    |> Enum.reject(fn c -> is_nil(c.date) end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(Decimal.new(0), fn [a, b], acc ->
      power_kw = effective_power(b)
      seconds = DateTime.diff(b.date, a.date, :second)

      if power_kw != nil and seconds > 0 do
        # energy = power (kW) * time (hours)
        energy = Decimal.mult(power_kw, Decimal.div(Decimal.new(seconds), Decimal.new(3600)))

        if Decimal.compare(energy, 0) != :lt do
          Decimal.add(acc, energy)
        else
          acc
        end
      else
        acc
      end
    end)
    |> Decimal.round(2)
    |> case do
      %Decimal{} = d -> if Decimal.compare(d, 0) == :gt, do: d, else: nil
    end
  end

  # Effective charging power in kW for a charge row.
  # Prefers current * voltage * phases (more accurate), falls back to charger_power.
  defp effective_power(%{charger_actual_current: amps, charger_voltage: volts, charger_phases: phases})
       when is_integer(amps) and is_integer(volts) and amps > 0 and volts > 0 do
    p = (phases || 1) |> max(1)
    Decimal.div(Decimal.new(amps * volts * p), Decimal.new(1000))
  end

  defp effective_power(%{charger_power: power}) when is_integer(power) and power > 0 do
    Decimal.new(power)
  end

  defp effective_power(_), do: nil

  @doc "Maps a TeslaLogger car_version row to TeslaMate update attrs."
  def map_update(row, timezone) do
    %{
      start_date: to_utc(row["StartDate"], timezone),
      version: row["version"]
    }
  end

  @doc """
  Consolidates consecutive updates with the same version into a single entry.
  Keeps the earliest start_date for each version run.
  Must be called BEFORE add_update_end_dates.
  """
  def consolidate_updates(updates) do
    updates
    |> Enum.chunk_while(
      nil,
      fn update, acc ->
        case acc do
          nil ->
            {:cont, update}

          prev when prev.version == update.version ->
            # Same version — keep earliest start_date (prev is already earlier since list is sorted)
            {:cont, prev}

          prev ->
            # Different version — emit previous, start new accumulator
            {:cont, prev, update}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
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

  defp decimal_avg(records, field_fn) do
    values =
      records
      |> Enum.map(field_fn)
      |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vals ->
        sum = Enum.reduce(vals, Decimal.new(0), &Decimal.add/2)
        Decimal.round(Decimal.div(sum, Decimal.new(length(vals))), 2)
    end
  end

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
      {:ok, dt} -> shift_to_utc(dt)
      {:ambiguous, dt, _} -> shift_to_utc(dt)
      {:gap, _, dt} -> shift_to_utc(dt)
      {:error, reason} ->
        Logger.warning("Failed to convert #{ndt} in timezone #{timezone}: #{inspect(reason)}")
        nil
    end
  end

  defp to_utc(%DateTime{} = dt, _timezone), do: shift_to_utc(dt)

  defp to_utc(_, _timezone), do: nil

  defp shift_to_utc(dt) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc} ->
        ensure_usec(utc)

      {:error, reason} ->
        Logger.warning("Failed to shift #{inspect(dt)} to UTC: #{inspect(reason)}, using as-is")
        ensure_usec(dt)
    end
  end

  defp ensure_usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

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

  # Filter out (0, 0) coordinates — GPS error when no signal (e.g. underground parking)
  # Also handles string inputs from MySQL driver by converting first
  defp sanitize_coords(lat, lng) do
    lat_num = to_number_for_coord(lat)
    lng_num = to_number_for_coord(lng)

    if (lat_num == 0 and lng_num == 0) or lat_num == nil or lng_num == nil do
      {nil, nil}
    else
      {lat_num, lng_num}
    end
  end

  defp to_number_for_coord(val) when is_number(val), do: val
  defp to_number_for_coord(%Decimal{} = d), do: Decimal.to_float(d)

  defp to_number_for_coord(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp to_number_for_coord(_), do: nil

  # Ensures end_date is strictly after start_date. TeslaLogger often records
  # very short drives/charges where start == end (car briefly wakes up).
  defp ensure_end_after_start(nil, end_date), do: end_date
  defp ensure_end_after_start(_start_date, nil), do: nil

  defp ensure_end_after_start(%DateTime{} = start_date, %DateTime{} = end_date) do
    if DateTime.compare(start_date, end_date) != :lt do
      start_date |> DateTime.add(1, :second) |> ensure_usec()
    else
      end_date
    end
  end

  # Known DC fast charger types from Tesla API
  @dc_charger_types ~w(Combo CCS CHAdeMO Tesla SuperCharger)

  defp is_dc_charger?(row) do
    phases = to_integer(row["charger_phases"])
    max_power = to_float(row["max_charger_power"])
    type = non_empty_string(row["fast_charger_type"])

    cond do
      # 1. Session-level max power — most reliable indicator.
      #    AC tops out at ~22 kW (3-phase 32A), DC starts at ~25 kW minimum.
      max_power != nil and max_power > 25 ->
        true

      # 2. Known DC charger type from Tesla API (e.g. "Tesla", "CCS", "CHAdeMO")
      type != nil and type in @dc_charger_types ->
        true

      # 3. AC charging always reports phases (1-3, TL sometimes stores 4).
      #    Checked AFTER power/type so a 150 kW Supercharger with phases=1 isn't misclassified.
      phases != nil and phases > 0 ->
        false

      # 4. Low max_power with no phases → AC
      max_power != nil and max_power <= 25 ->
        false

      # 5. Last resort: per-row charger_power
      true ->
        power = to_integer(row["charger_power"])
        power != nil and power > 25
    end
  end

  # TeslaLogger sometimes stores 4 phases (3-phase + neutral), but TeslaMate
  # only accepts 1-3. Clamp to valid range.
  defp clamp_phases(nil), do: nil
  defp clamp_phases(p) when p > 3, do: 3
  defp clamp_phases(p) when p < 1, do: nil
  defp clamp_phases(p), do: p

  defp non_empty_string(nil), do: nil
  defp non_empty_string(""), do: nil
  defp non_empty_string(s) when is_binary(s), do: s
  defp non_empty_string(_), do: nil

  defp distance(nil, _), do: nil
  defp distance(_, nil), do: nil
  defp distance(start_km, end_km), do: Float.round(end_km - start_km, 2)

  defp duration_minutes(nil, _), do: nil
  defp duration_minutes(_, nil), do: nil

  defp duration_minutes(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    DateTime.diff(end_dt, start_dt, :second) |> div(60)
  end
end
