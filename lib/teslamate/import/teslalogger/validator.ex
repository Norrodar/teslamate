defmodule TeslaMate.Import.TeslaLogger.Validator do
  @moduledoc false

  defmodule ValidationError do
    @moduledoc false
    defstruct [:table, :row_id, :field, :message, :severity]

    @type t :: %__MODULE__{
            table: String.t(),
            row_id: term(),
            field: atom() | nil,
            message: String.t(),
            severity: :error | :warning
          }
  end

  @doc "Validates a list of mapped position attrs. Returns {valid_positions, errors}."
  def validate_positions(positions) do
    {valid, errors} =
      positions
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {pos, idx}, {valid_acc, err_acc} ->
        errs = validate_position(pos, idx)

        has_errors = Enum.any?(errs, &(&1.severity == :error))

        if has_errors do
          {valid_acc, errs ++ err_acc}
        else
          {[pos | valid_acc], errs ++ err_acc}
        end
      end)

    {Enum.reverse(valid), errors}
  end

  @doc "Validates a list of mapped drive attrs. Returns {valid_drives, errors}."
  def validate_drives(drives) do
    {valid, errors} =
      drives
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {drive, idx}, {valid_acc, err_acc} ->
        errs = validate_drive(drive, idx)
        has_errors = Enum.any?(errs, &(&1.severity == :error))

        if has_errors do
          {valid_acc, errs ++ err_acc}
        else
          {[drive | valid_acc], errs ++ err_acc}
        end
      end)

    overlap_errors = check_overlaps(Enum.reverse(valid), :drives)
    {Enum.reverse(valid), errors ++ overlap_errors}
  end

  @doc "Validates a list of mapped charge attrs. Returns {valid_charges, errors}."
  def validate_charges(charges) do
    {valid, errors} =
      charges
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {charge, idx}, {valid_acc, err_acc} ->
        errs = validate_charge(charge, idx)
        has_errors = Enum.any?(errs, &(&1.severity == :error))

        if has_errors do
          {valid_acc, errs ++ err_acc}
        else
          {[charge | valid_acc], errs ++ err_acc}
        end
      end)

    {Enum.reverse(valid), errors}
  end

  @doc "Validates a list of mapped charging_process attrs. Returns {valid, errors}."
  def validate_charging_processes(processes) do
    {valid, errors} =
      processes
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {cp, idx}, {valid_acc, err_acc} ->
        errs = validate_charging_process(cp, idx)
        has_errors = Enum.any?(errs, &(&1.severity == :error))

        if has_errors do
          {valid_acc, errs ++ err_acc}
        else
          {[cp | valid_acc], errs ++ err_acc}
        end
      end)

    overlap_errors = check_overlaps(Enum.reverse(valid), :charging_processes)
    {Enum.reverse(valid), errors ++ overlap_errors}
  end

  @doc "Returns a summary of validation warnings as strings."
  def format_warnings(errors) do
    errors
    |> Enum.filter(&(&1.severity == :warning))
    |> Enum.map(fn %ValidationError{table: t, row_id: id, field: f, message: m} ->
      "[#{t}##{id}] #{f}: #{m}"
    end)
    |> Enum.take(100)
  end

  ## Private - Position validation

  defp validate_position(pos, idx) do
    []
    |> check_required(pos, :date, "positions", idx)
    |> check_required(pos, :latitude, "positions", idx)
    |> check_required(pos, :longitude, "positions", idx)
    |> check_range(pos, :latitude, -90, 90, "positions", idx)
    |> check_range(pos, :longitude, -180, 180, "positions", idx)
    |> check_range(pos, :battery_level, 0, 100, "positions", idx)
    |> check_non_negative(pos, :speed, "positions", idx)
    |> check_not_future(pos, :date, "positions", idx)
  end

  ## Private - Drive validation

  defp validate_drive(drive, idx) do
    []
    |> check_required(drive, :start_date, "drives", idx)
    |> check_date_order(drive, :start_date, :end_date, "drives", idx)
    |> check_non_negative(drive, :speed_max, "drives", idx)
  end

  ## Private - Charge validation

  defp validate_charge(charge, idx) do
    []
    |> check_required(charge, :date, "charges", idx)
    |> check_range(charge, :battery_level, 0, 100, "charges", idx)
    |> check_non_negative_decimal(charge, :charge_energy_added, "charges", idx)
    |> check_non_negative(charge, :charger_power, "charges", idx)
    |> check_in_set(charge, :charger_phases, [1, 2, 3, nil], "charges", idx)
  end

  ## Private - Charging process validation

  defp validate_charging_process(cp, idx) do
    []
    |> check_required(cp, :start_date, "charging_processes", idx)
    |> check_date_order(cp, :start_date, :end_date, "charging_processes", idx)
    |> check_non_negative_decimal(cp, :charge_energy_added, "charging_processes", idx)
  end

  ## Private - Overlap detection

  defp check_overlaps(items, table) do
    items
    |> Enum.sort_by(& &1.start_date, &(DateTime.compare(&1, &2) != :gt))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      if a.end_date != nil and b.start_date != nil and
           DateTime.compare(a.end_date, b.start_date) == :gt do
        [
          %ValidationError{
            table: Atom.to_string(table),
            row_id: "overlap",
            field: :start_date,
            message: "Overlap: #{a.start_date} - #{a.end_date} overlaps with #{b.start_date}",
            severity: :warning
          }
        ]
      else
        []
      end
    end)
  end

  ## Private - Generic checks

  defp check_required(errors, map, field, table, idx) do
    if Map.get(map, field) == nil do
      [
        %ValidationError{
          table: table,
          row_id: idx,
          field: field,
          message: "required field is nil",
          severity: :error
        }
        | errors
      ]
    else
      errors
    end
  end

  defp check_range(errors, map, field, min, max, table, idx) do
    val = Map.get(map, field)

    cond do
      val == nil ->
        errors

      is_number(val) and (val < min or val > max) ->
        [
          %ValidationError{
            table: table,
            row_id: idx,
            field: field,
            message: "value #{val} outside range [#{min}, #{max}]",
            severity: :warning
          }
          | errors
        ]

      match?(%Decimal{}, val) ->
        num = Decimal.to_float(val)

        if num < min or num > max do
          [
            %ValidationError{
              table: table,
              row_id: idx,
              field: field,
              message: "value #{val} outside range [#{min}, #{max}]",
              severity: :warning
            }
            | errors
          ]
        else
          errors
        end

      true ->
        errors
    end
  end

  defp check_non_negative(errors, map, field, table, idx) do
    val = Map.get(map, field)

    if is_number(val) and val < 0 do
      [
        %ValidationError{
          table: table,
          row_id: idx,
          field: field,
          message: "negative value: #{val}",
          severity: :warning
        }
        | errors
      ]
    else
      errors
    end
  end

  defp check_non_negative_decimal(errors, map, field, table, idx) do
    val = Map.get(map, field)

    cond do
      val == nil ->
        errors

      match?(%Decimal{}, val) and Decimal.compare(val, Decimal.new(0)) == :lt ->
        [
          %ValidationError{
            table: table,
            row_id: idx,
            field: field,
            message: "negative value: #{val}",
            severity: :warning
          }
          | errors
        ]

      true ->
        errors
    end
  end

  defp check_date_order(errors, map, start_field, end_field, table, idx) do
    start_val = Map.get(map, start_field)
    end_val = Map.get(map, end_field)

    if start_val != nil and end_val != nil and DateTime.compare(start_val, end_val) != :lt do
      [
        %ValidationError{
          table: table,
          row_id: idx,
          field: start_field,
          message: "start_date (#{start_val}) not before end_date (#{end_val})",
          severity: :warning
        }
        | errors
      ]
    else
      errors
    end
  end

  defp check_not_future(errors, map, field, table, idx) do
    val = Map.get(map, field)

    if val != nil and DateTime.compare(val, DateTime.utc_now()) == :gt do
      [
        %ValidationError{
          table: table,
          row_id: idx,
          field: field,
          message: "timestamp is in the future: #{val}",
          severity: :warning
        }
        | errors
      ]
    else
      errors
    end
  end

  defp check_in_set(errors, map, field, allowed, table, idx) do
    val = Map.get(map, field)

    if val != nil and val not in allowed do
      [
        %ValidationError{
          table: table,
          row_id: idx,
          field: field,
          message: "value #{val} not in allowed set #{inspect(allowed)}",
          severity: :warning
        }
        | errors
      ]
    else
      errors
    end
  end
end
