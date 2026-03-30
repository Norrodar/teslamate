defmodule TeslaMate.Import.TeslaLogger.Writer do
  @moduledoc false

  import Ecto.Query

  alias TeslaMate.Log.{Position, Drive, ChargingProcess, Charge, State, Update}
  alias TeslaMate.Repo

  require Logger

  @batch_size 1000

  @doc """
  Inserts positions in batches within transactions.
  Returns {:ok, date_to_pos_id_map} or {:error, reason}.
  """
  def insert_positions(car_id, positions, progress_fn \\ fn _, _ -> :ok end) do
    total = length(positions)
    Logger.info("Inserting #{total} positions...")

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
            :is_front_defroster_on
          ])
        end)

      case Repo.transaction(fn ->
        Repo.insert_all(Position, entries, returning: [:id, :date])
      end) do
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
      {count, date_map} ->
        Logger.info("Inserted #{count}/#{total} positions")
        {:ok, date_map}
    end
  end

  @doc """
  Inserts drives within a transaction. Returns {:ok, [{drive_id, start_date, end_date}]}.
  """
  def insert_drives(car_id, drives) do
    Repo.transaction(fn ->
      Enum.reduce(drives, [], fn drive_attrs, acc ->
        entry =
          drive_attrs
          |> Map.put(:car_id, car_id)
          |> Map.take([
            :car_id, :start_date, :end_date, :outside_temp_avg, :inside_temp_avg,
            :speed_max, :power_max, :power_min, :start_ideal_range_km, :end_ideal_range_km,
            :start_rated_range_km, :end_rated_range_km, :start_km, :end_km,
            :distance, :duration_min, :start_position_id, :end_position_id
          ])

        case %Drive{car_id: car_id} |> Drive.changeset(entry) |> Repo.insert() do
          {:ok, drive} ->
            [{drive.id, drive_attrs.start_date, drive_attrs.end_date} | acc]

          {:error, changeset} ->
            Logger.warning("Skipping drive at #{drive_attrs.start_date}: #{inspect(changeset.errors)}")
            acc
        end
      end)
      |> Enum.reverse()
    end)
  end

  @doc """
  Associates positions with drives by updating drive_id based on date ranges.
  Uses pre-sorted date list for efficient range lookup.
  """
  def associate_positions_with_drives(drives_with_ids, date_to_pos_id) do
    # Pre-sort dates once for efficient range queries
    sorted_entries =
      date_to_pos_id
      |> Enum.sort_by(fn {date, _id} -> date end, &(DateTime.compare(&1, &2) != :gt))

    Enum.each(drives_with_ids, fn {drive_id, start_date, end_date} ->
      # Filter positions in this drive's time range
      pos_ids =
        sorted_entries
        |> Enum.drop_while(fn {date, _} -> DateTime.compare(date, start_date) == :lt end)
        |> Enum.take_while(fn {date, _} ->
          end_date == nil or DateTime.compare(date, end_date) != :gt
        end)
        |> Enum.map(fn {_, id} -> id end)

      if pos_ids != [] do
        {updated, _} =
          from(p in Position, where: p.id in ^pos_ids)
          |> Repo.update_all(set: [drive_id: drive_id])

        Logger.debug("Associated #{updated} positions with drive #{drive_id}")

        first_pos_id = List.first(pos_ids)
        last_pos_id = List.last(pos_ids)

        from(d in Drive, where: d.id == ^drive_id)
        |> Repo.update_all(
          set: [start_position_id: first_pos_id, end_position_id: last_pos_id]
        )
      end
    end)

    :ok
  end

  @doc """
  Inserts charging processes within a transaction.
  Returns {:ok, [{tl_id, tm_id}]} for charge association.
  """
  def insert_charging_processes(car_id, processes_with_tl_ids, date_to_pos_id) do
    Repo.transaction(fn ->
      Enum.reduce(processes_with_tl_ids, %{}, fn {tl_id, cp_attrs}, acc ->
        position_id = find_nearest_position(cp_attrs.start_date, date_to_pos_id)

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

        case %ChargingProcess{car_id: car_id, position_id: position_id}
             |> ChargingProcess.changeset(entry)
             |> Repo.insert() do
          {:ok, cp} ->
            Map.put(acc, tl_id, cp.id)

          {:error, changeset} ->
            Logger.warning("Skipping charging_process at #{cp_attrs.start_date}: #{inspect(changeset.errors)}")
            acc
        end
      end)
    end)
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
    Logger.info("Inserting #{total} charges...")

    valid
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(0, fn batch, inserted ->
      entries =
        Enum.map(batch, fn charge ->
          charge
          |> Map.take([
            :charging_process_id, :date, :battery_level, :usable_battery_level,
            :charge_energy_added, :charger_actual_current, :charger_phases,
            :charger_pilot_current, :charger_power, :charger_voltage,
            :conn_charge_cable, :fast_charger_present, :fast_charger_brand,
            :fast_charger_type, :ideal_battery_range_km, :rated_battery_range_km,
            :outside_temp, :battery_heater, :battery_heater_on,
            :battery_heater_no_power, :not_enough_power_to_heat
          ])
          |> ensure_charge_defaults()
        end)

      case Repo.transaction(fn -> Repo.insert_all(Charge, entries) end) do
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
        Logger.info("Inserted #{count}/#{total} charges")
        {:ok, count}
    end
  end

  @doc "Inserts states within a transaction."
  def insert_states(car_id, states) do
    Repo.transaction(fn ->
      Enum.reduce(states, 0, fn state_attrs, count ->
        entry =
          state_attrs
          |> Map.put(:car_id, car_id)
          |> Map.take([:car_id, :state, :start_date, :end_date])

        case %State{car_id: car_id} |> State.changeset(entry) |> Repo.insert() do
          {:ok, _} ->
            count + 1

          {:error, changeset} ->
            Logger.warning("Skipping state at #{state_attrs.start_date}: #{inspect(changeset.errors)}")
            count
        end
      end)
    end)
  end

  @doc "Inserts updates within a transaction."
  def insert_updates(car_id, updates) do
    Repo.transaction(fn ->
      Enum.reduce(updates, 0, fn update_attrs, count ->
        entry =
          update_attrs
          |> Map.put(:car_id, car_id)
          |> Map.take([:car_id, :start_date, :end_date, :version])

        case %Update{car_id: car_id} |> Update.changeset(entry) |> Repo.insert() do
          {:ok, _} ->
            count + 1

          {:error, changeset} ->
            Logger.warning("Skipping update at #{update_attrs.start_date}: #{inspect(changeset.errors)}")
            count
        end
      end)
    end)
  end

  ## Private

  defp find_nearest_position(nil, _date_to_pos_id), do: nil

  defp find_nearest_position(target_date, date_to_pos_id) do
    date_to_pos_id
    |> Enum.min_by(
      fn {date, _id} -> abs(DateTime.diff(date, target_date, :second)) end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {_date, id} -> id
    end
  end

  defp ensure_charge_defaults(charge) do
    charge
    |> Map.put_new(:charger_phases, 1)
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
end
