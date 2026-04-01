defmodule TeslaMate.Import.TeslaLogger.Writer do
  @moduledoc false

  import Ecto.Query

  alias TeslaMate.Log.{Car, Position, Drive, ChargingProcess, Charge, State, Update}
  alias TeslaMate.Repo

  require Logger

  @batch_size 1000
  @progress_interval 100
  @transaction_timeout :infinity

  @doc """
  Inserts positions in batches within transactions.
  Returns {:ok, date_to_pos_id_map} or {:error, reason}.
  """
  def insert_positions(car_id, positions, progress_fn \\ fn _, _ -> :ok end) do
    total = length(positions)

    positions
    |> Enum.map(&Map.put(&1, :car_id, car_id))
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({0, %{}}, fn batch, {inserted, date_map} ->
      entries =
        Enum.map(batch, fn pos ->
          pos
          |> Map.take([
            :car_id, :date, :latitude, :longitude, :elevation, :speed, :power,
            :odometer, :ideal_battery_range_km, :est_battery_range_km,
            :rated_battery_range_km, :battery_level, :usable_battery_level,
            :battery_heater, :battery_heater_on, :battery_heater_no_power,
            :outside_temp, :inside_temp, :fan_status, :driver_temp_setting,
            :passenger_temp_setting, :is_climate_on, :is_rear_defroster_on,
            :is_front_defroster_on,
            :tpms_pressure_fl, :tpms_pressure_fr,
            :tpms_pressure_rl, :tpms_pressure_rr
          ])
        end)

      case Repo.transaction(fn ->
        Repo.insert_all(Position, entries, returning: [:id, :date])
      end, timeout: @transaction_timeout) do
        {:ok, {count, results}} ->
          new_inserted = inserted + count
          progress_fn.(new_inserted, total)

          new_date_map =
            Enum.reduce(results, date_map, fn %{id: id, date: date}, acc ->
              Map.put_new(acc, date, id)
            end)

          {:cont, {new_inserted, new_date_map}}

        {:error, reason} ->
          Logger.error("Failed to insert position batch at offset #{inserted}: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {_count, date_map} ->
        {:ok, date_map}
    end
  end

  @doc """
  Inserts drives within a transaction. Returns {:ok, [{drive_id, start_date, end_date}]}.
  """
  def insert_drives(car_id, drives, progress_fn \\ fn _, _ -> :ok end) do
    total = length(drives)

    Repo.transaction(fn ->
      {result, _count} =
        Enum.map_reduce(drives, 0, fn drive_attrs, count ->
          entry =
            drive_attrs

            |> Map.put(:car_id, car_id)
            |> Map.take([
              :car_id, :start_date, :end_date, :outside_temp_avg, :inside_temp_avg,
              :speed_max, :power_max, :power_min, :start_ideal_range_km, :end_ideal_range_km,
              :start_rated_range_km, :end_rated_range_km, :start_km, :end_km,
              :distance, :duration_min, :start_position_id, :end_position_id
            ])

          item =
            case %Drive{car_id: car_id} |> Drive.changeset(entry) |> Repo.insert() do
              {:ok, drive} ->
                {drive.id, drive_attrs.start_date, drive_attrs.end_date}

              {:error, changeset} ->
                Logger.warning("Skipping drive at #{drive_attrs.start_date}: #{inspect(changeset.errors)}")
                nil
            end

          new_count = count + 1

          if rem(new_count, @progress_interval) == 0, do: progress_fn.(new_count, total)
          {item, new_count}
        end)

      Enum.reject(result, &is_nil/1)
    end, timeout: @transaction_timeout)
  end

  @doc """
  Associates positions with drives by updating drive_id based on date ranges.
  Uses pre-sorted date list for efficient range lookup.
  """
  def associate_positions_with_drives(drives_with_ids, date_to_pos_id, progress_fn \\ fn _, _ -> :ok end) do
    sorted_array = build_sorted_array(date_to_pos_id, fn {dt, _id} -> dt end, fn {_dt, id} -> id end)
    total = length(drives_with_ids)

    drives_with_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {{drive_id, start_date, end_date}, idx} ->
      start_unix = DateTime.to_unix(start_date, :second)
      end_unix = if end_date, do: DateTime.to_unix(end_date, :second), else: :infinity
      pos_ids = collect_ids_in_range(sorted_array, start_unix, end_unix)

      if pos_ids != [] do
        from(p in Position, where: p.id in ^pos_ids)
        |> Repo.update_all(set: [drive_id: drive_id])

        first_pos_id = List.first(pos_ids)
        last_pos_id = List.last(pos_ids)

        from(d in Drive, where: d.id == ^drive_id)
        |> Repo.update_all(
          set: [start_position_id: first_pos_id, end_position_id: last_pos_id]
        )
      end

      if rem(idx, @progress_interval) == 0 do
        progress_fn.(idx, total)
      end
    end)

    :ok
  end

  @doc """
  Inserts charging processes within a transaction.
  Returns {:ok, [{tl_id, tm_id}]} for charge association.
  """
  def insert_charging_processes(car_id, processes_with_tl_ids, date_to_pos_id, progress_fn \\ fn _, _ -> :ok end) do
    total = length(processes_with_tl_ids)

    pos_sorted_array = build_sorted_array(date_to_pos_id, fn {dt, _} -> dt end, fn {_, id} -> id end)

    Repo.transaction(fn ->
      {result, _count} =
        Enum.map_reduce(processes_with_tl_ids, 0, fn {tl_id, cp_attrs}, count ->
          position_id =
            if cp_attrs.start_date do
              find_nearest(pos_sorted_array, DateTime.to_unix(cp_attrs.start_date, :second))
            end


          if is_nil(position_id) do
            Logger.warning("No nearby position for charging process at #{cp_attrs.start_date}")
          end

          entry =
            cp_attrs
            |> Map.put(:car_id, car_id)
            |> Map.take([
              :car_id, :start_date, :end_date, :charge_energy_added,
              :charge_energy_used, :start_ideal_range_km, :end_ideal_range_km,
              :start_rated_range_km, :end_rated_range_km, :start_battery_level,
              :end_battery_level, :duration_min, :outside_temp_avg, :cost
            ])

          item =
            case %ChargingProcess{car_id: car_id, position_id: position_id}
                 |> ChargingProcess.changeset(entry)
                 |> Repo.insert() do
              {:ok, cp} ->
                {tl_id, cp.id}

              {:error, changeset} ->
                Logger.warning("Skipping charging_process at #{cp_attrs.start_date}: #{inspect(changeset.errors)}")
                nil
            end

          new_count = count + 1
          if rem(new_count, @progress_interval) == 0, do: progress_fn.(new_count, total)

          {item, new_count}
        end)

      result
      |> Enum.reject(&is_nil/1)
      |> Map.new()
    end, timeout: @transaction_timeout)
  end

  @doc """
  Inserts charges in batches within transactions.
  Logs dropped charges (those without a matching charging_process).
  """
  def insert_charges(charges, tl_cs_id_to_cp_id, progress_fn \\ fn _, _ -> :ok end) do
    charges_with_cp =
      Enum.map(charges, fn charge ->
        cp_id = Map.get(tl_cs_id_to_cp_id, charge[:tl_chargingstate_id])
        Map.put(charge, :charging_process_id, cp_id)
      end)

    {valid, dropped} = Enum.split_with(charges_with_cp, &(&1.charging_process_id != nil))

    if dropped != [] do
      Logger.warning("Dropped #{length(dropped)} charges: no matching charging_process")
    end

    total = length(valid)

    valid
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(0, fn batch, inserted ->
      entries =
        Enum.map(batch, fn charge ->
          charge
          |> Map.take([
            :charging_process_id, :date, :battery_level,
            :charge_energy_added, :charger_actual_current, :charger_phases,
            :charger_pilot_current, :charger_power, :charger_voltage,
            :conn_charge_cable, :fast_charger_present, :fast_charger_brand,
            :fast_charger_type, :ideal_battery_range_km, :rated_battery_range_km,
            :outside_temp, :battery_heater, :battery_heater_on,
            :battery_heater_no_power, :not_enough_power_to_heat
          ])
          |> ensure_charge_defaults()
        end)

      case Repo.transaction(fn -> Repo.insert_all(Charge, entries) end, timeout: @transaction_timeout) do
        {:ok, {count, _}} ->
          new_inserted = inserted + count
          progress_fn.(new_inserted, total)
          {:cont, new_inserted}

        {:error, reason} ->
          Logger.error("Failed to insert charge batch at offset #{inserted}: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      count ->
        {:ok, count}
    end
  end

  @doc "Inserts states within a transaction."
  def insert_states(car_id, states, progress_fn \\ fn _, _ -> :ok end) do
    total = length(states)

    Repo.transaction(fn ->
      Enum.reduce(states, 0, fn state_attrs, count ->
        entry =
          state_attrs
          |> Map.put(:car_id, car_id)
          |> Map.take([:car_id, :state, :start_date, :end_date])

        new_count =
          case %State{car_id: car_id} |> State.changeset(entry) |> Repo.insert() do
            {:ok, _} -> count + 1
            {:error, changeset} ->
              Logger.warning("Skipping state at #{state_attrs.start_date}: #{inspect(changeset.errors)}")
              count
          end

        if rem(new_count, @progress_interval) == 0, do: progress_fn.(new_count, total)
        new_count
      end)
    end, timeout: @transaction_timeout)
  end

  @doc "Inserts updates within a transaction."
  def insert_updates(car_id, updates, progress_fn \\ fn _, _ -> :ok end) do
    total = length(updates)

    Repo.transaction(fn ->
      Enum.reduce(updates, 0, fn update_attrs, count ->
        entry =
          update_attrs
          |> Map.put(:car_id, car_id)
          |> Map.take([:car_id, :start_date, :end_date, :version])

        new_count =
          case %Update{car_id: car_id} |> Update.changeset(entry) |> Repo.insert() do
            {:ok, _} -> count + 1
            {:error, changeset} ->
              Logger.warning("Skipping update at #{update_attrs.start_date}: #{inspect(changeset.errors)}")
              count
          end

        if rem(new_count, @progress_interval) == 0, do: progress_fn.(new_count, total)
        new_count
      end)
    end, timeout: @transaction_timeout)
  end

  ## Import Mode Functions

  @doc """
  Checks that a car has no existing data in TeslaMate (for :clean mode).
  Returns :ok or {:error, {:data_exists, %{positions: n, drives: n, ...}}}.
  """
  def check_car_has_no_data(car_id) do
    counts = %{
      positions: Repo.aggregate(from(p in Position, where: p.car_id == ^car_id), :count),
      drives: Repo.aggregate(from(d in Drive, where: d.car_id == ^car_id), :count),
      charging_processes: Repo.aggregate(from(c in ChargingProcess, where: c.car_id == ^car_id), :count),
      states: Repo.aggregate(from(s in State, where: s.car_id == ^car_id), :count),
      updates: Repo.aggregate(from(u in Update, where: u.car_id == ^car_id), :count)
    }

    non_empty = counts |> Enum.filter(fn {_, v} -> v > 0 end) |> Map.new()

    if map_size(non_empty) == 0 do
      :ok
    else
      {:error, {:data_exists, non_empty}}
    end
  end

  @doc """
  Checks if a TeslaMate car exists for the given VIN and whether it has data.
  Returns {:ok, nil} if no car found, or {:ok, %{tm_car_id: id, tm_data_counts: counts}}.
  """
  def check_tm_data_for_vin(nil), do: {:ok, nil}
  def check_tm_data_for_vin(""), do: {:ok, nil}

  def check_tm_data_for_vin(vin) do
    case Repo.one(from(c in Car, where: c.vin == ^vin, select: c.id)) do
      nil ->
        {:ok, nil}

      car_id ->
        case check_car_has_no_data(car_id) do
          :ok ->
            {:ok, %{tm_car_id: car_id, tm_data_counts: %{}}}

          {:error, {:data_exists, counts}} ->
            {:ok, %{tm_car_id: car_id, tm_data_counts: counts}}
        end
    end
  end

  @doc """
  Loads existing position dates for a car as a MapSet of unix seconds.
  Used for merge mode B (TeslaMate priority) to skip existing timestamps.
  """
  def load_existing_position_dates(car_id) do
    from(p in Position, where: p.car_id == ^car_id, select: p.date)
    |> Repo.all()
    |> Enum.map(&DateTime.to_unix(&1, :second))
    |> MapSet.new()
  end

  @doc """
  Loads existing date ranges for a given entity type.
  Returns [{start_date, end_date}] sorted by start_date.
  """
  @range_queryables %{
    drives: Drive,
    charging_processes: ChargingProcess,
    states: State,
    updates: Update
  }

  def load_existing_ranges(car_id, entity) when is_map_key(@range_queryables, entity) do
    queryable = @range_queryables[entity]

    from(r in queryable,
      where: r.car_id == ^car_id,
      select: {r.start_date, r.end_date},
      order_by: r.start_date
    )
    |> Repo.all()
  end

  @doc """
  Filters out records that overlap with any existing range.
  Records must have :start_date and :end_date keys.
  """
  def filter_non_overlapping(records, existing_ranges) do
    Enum.reject(records, fn record ->
      overlaps_any_range?(record.start_date, record.end_date, existing_ranges)
    end)
  end

  @doc """
  Deletes records in a queryable that overlap with consolidated time ranges.
  FK-safe deletion order for Mode C (TeslaLogger priority):
  1. charging_processes (has ON DELETE RESTRICT on position_id)
  2. positions
  3. drives
  4. states, updates
  """
  def delete_overlapping_data(car_id, consolidated_ranges) do
    # FK-safe order: CPs (RESTRICT on position_id) → positions → drives → states → updates
    cp_deleted = delete_overlapping_ranges(car_id, ChargingProcess, consolidated_ranges)
    cp_orphan_deleted = delete_charging_processes_referencing_positions(car_id, consolidated_ranges)
    pos_deleted = delete_positions_in_ranges(car_id, consolidated_ranges)
    drives_deleted = delete_overlapping_ranges(car_id, Drive, consolidated_ranges)
    states_deleted = delete_overlapping_ranges(car_id, State, consolidated_ranges)
    updates_deleted = delete_overlapping_ranges(car_id, Update, consolidated_ranges)

    result = %{
      charging_processes: cp_deleted + cp_orphan_deleted,
      positions: pos_deleted,
      drives: drives_deleted,
      states: states_deleted,
      updates: updates_deleted
    }

    Logger.info("Pre-deletion complete: #{inspect(result)}")
    result
  end

  @doc "Deletes range-based records that overlap with any of the consolidated ranges."
  def delete_overlapping_ranges(car_id, queryable, consolidated_ranges) do
    delete_in_ranges(consolidated_ranges, fn range_start, range_end ->
      if range_end == nil do
        from(r in queryable,
          where: r.car_id == ^car_id and (is_nil(r.end_date) or r.end_date >= ^range_start))
      else
        from(r in queryable,
          where: r.car_id == ^car_id
            and r.start_date <= ^range_end
            and (is_nil(r.end_date) or r.end_date >= ^range_start))
      end
    end)
  end

  @doc "Deletes point-in-time positions within consolidated time ranges."
  def delete_positions_in_ranges(car_id, consolidated_ranges) do
    delete_in_ranges(consolidated_ranges, fn range_start, range_end ->
      if range_end == nil do
        from(p in Position, where: p.car_id == ^car_id and p.date >= ^range_start)
      else
        from(p in Position,
          where: p.car_id == ^car_id and p.date >= ^range_start and p.date <= ^range_end)
      end
    end)
  end

  defp delete_in_ranges(consolidated_ranges, query_builder_fn) do
    Enum.reduce(consolidated_ranges, 0, fn {range_start, range_end}, total ->
      {deleted, _} = query_builder_fn.(range_start, range_end) |> Repo.delete_all()
      total + deleted
    end)
  end

  @doc """
  Deletes charging_processes whose position_id references a position
  that falls within the consolidated time ranges. This prevents FK violations
  when positions are deleted, because charging_processes.position_id is
  NOT NULL with ON DELETE RESTRICT.
  """
  def delete_charging_processes_referencing_positions(car_id, consolidated_ranges) do
    delete_in_ranges(consolidated_ranges, fn range_start, range_end ->
      pos_ids_query =
        if range_end == nil do
          from(p in Position, where: p.car_id == ^car_id and p.date >= ^range_start, select: p.id)
        else
          from(p in Position,
            where: p.car_id == ^car_id and p.date >= ^range_start and p.date <= ^range_end,
            select: p.id)
        end

      from(cp in ChargingProcess,
        where: cp.car_id == ^car_id and cp.position_id in subquery(pos_ids_query))
    end)
  end

  @doc """
  Merges overlapping/adjacent time ranges into consolidated blocks.
  Input: [{start_date, end_date}] (unsorted ok)
  Output: [{start_date, end_date}] sorted, non-overlapping
  """
  def consolidate_ranges([]), do: []

  def consolidate_ranges(ranges) do
    ranges
    |> Enum.reject(fn {s, _e} -> is_nil(s) end)
    |> Enum.sort_by(fn {s, _e} -> DateTime.to_unix(s, :second) end)
    |> Enum.reduce([], fn
      {s, e}, [] ->
        [{s, e}]

      {s, e}, [{prev_s, prev_e} | rest] ->
        if prev_e == nil or DateTime.compare(s, prev_e) != :gt do
          # Overlapping or adjacent — merge
          merged_end =
            cond do
              prev_e == nil -> nil
              e == nil -> nil
              true -> max_datetime(prev_e, e)
            end

          [{prev_s, merged_end} | rest]
        else
          [{s, e}, {prev_s, prev_e} | rest]
        end
    end)
    |> Enum.reverse()
  end

  ## Sorted Array Helpers (binary search on {:erlang.array})

  @doc """
  Builds a sorted `:array` of `{unix_seconds, value}` tuples from a map.
  `key_fn` extracts the DateTime, `val_fn` extracts the value to store.
  """
  def build_sorted_array(enumerable, key_fn, val_fn) do
    enumerable
    |> Enum.map(fn item -> {DateTime.to_unix(key_fn.(item), :second), val_fn.(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> :array.from_list()
  end

  @doc "Finds all values in `sorted_array` between `start_date` and `end_date`."
  def find_in_sorted_array(sorted_array, start_date, end_date) do
    size = :array.size(sorted_array)
    if size == 0, do: [], else: do_find_in_range(sorted_array, size, start_date, end_date)
  end

  @doc "Finds all IDs in `sorted_array` between `start_unix` and `end_unix`."
  def collect_ids_in_range(sorted_array, start_unix, end_unix) do
    idx = binary_search_left(sorted_array, start_unix)
    collect_until(sorted_array, idx, :array.size(sorted_array), end_unix, &elem(&1, 1))
  end

  @doc "Finds the ID of the nearest entry to `target_unix`."
  def find_nearest(sorted_array, target_unix) do
    size = :array.size(sorted_array)

    if size == 0 do
      nil
    else
      idx = binary_search_left(sorted_array, target_unix)

      cond do
        idx >= size -> elem(:array.get(size - 1, sorted_array), 1)
        idx == 0 -> elem(:array.get(0, sorted_array), 1)
        true ->
          {unix_left, val_left} = :array.get(idx - 1, sorted_array)
          {unix_right, val_right} = :array.get(idx, sorted_array)
          if abs(target_unix - unix_left) <= abs(unix_right - target_unix), do: val_left, else: val_right
      end
    end
  end

  ## Private

  defp do_find_in_range(arr, size, start_date, end_date) do
    start_unix = DateTime.to_unix(start_date, :second)
    end_unix = if end_date, do: DateTime.to_unix(end_date, :second), else: :infinity
    idx = binary_search_left(arr, start_unix)
    collect_until(arr, idx, size, end_unix, &elem(&1, 1))
  end

  defp binary_search_left(arr, target_unix) do
    binary_search_left(arr, target_unix, 0, :array.size(arr))
  end

  defp binary_search_left(_arr, _target, lo, hi) when lo >= hi, do: lo

  defp binary_search_left(arr, target, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(:array.get(mid, arr), 0) < target do
      binary_search_left(arr, target, mid + 1, hi)
    else
      binary_search_left(arr, target, lo, mid)
    end
  end

  defp collect_until(arr, idx, size, end_unix, extract_fn) do
    collect_until(arr, idx, size, end_unix, extract_fn, [])
  end

  defp collect_until(_arr, idx, size, _end_unix, _extract_fn, acc) when idx >= size,
    do: Enum.reverse(acc)

  defp collect_until(arr, idx, size, end_unix, extract_fn, acc) do
    entry = :array.get(idx, arr)
    unix = elem(entry, 0)

    if end_unix != :infinity and unix > end_unix do
      Enum.reverse(acc)
    else
      collect_until(arr, idx + 1, size, end_unix, extract_fn, [extract_fn.(entry) | acc])
    end
  end

  defp ensure_charge_defaults(charge) do
    charge
    # For DC charges (charger_phases = nil), keep nil so Grafana detects DC correctly.
    # For AC charges, default nil/0 to 1.
    # Grafana logic: NULLIF(mode(charger_phases), 0) IS NULL → DC, else AC
    |> Map.update(:charger_phases, nil, fn
      nil -> nil
      0 -> nil
      val -> val
    end)
    |> Map.update(:charge_energy_added, Decimal.new(0), fn
      nil -> Decimal.new(0)
      val -> val
    end)
    |> Map.update(:charger_power, 0, fn
      nil -> 0
      val -> val
    end)
    |> Map.update(:ideal_battery_range_km, Decimal.new(0), fn
      nil -> Decimal.new(0)
      val -> val
    end)
  end

  defp overlaps_any_range?(_start_date, _end_date, []), do: false

  defp overlaps_any_range?(start_date, end_date, existing_ranges) do
    Enum.any?(existing_ranges, fn {tm_start, tm_end} ->
      # Two ranges overlap when: A_start < B_end AND A_end > B_start
      # Handle nil end_dates (open-ended ranges) as "infinity"
      start_before_end =
        case tm_end do
          nil -> true
          _ -> DateTime.compare(start_date, tm_end) == :lt
        end

      end_after_start =
        case end_date do
          nil -> true
          _ -> DateTime.compare(end_date, tm_start) == :gt
        end

      start_before_end and end_after_start
    end)
  end

  defp max_datetime(a, b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end
end
