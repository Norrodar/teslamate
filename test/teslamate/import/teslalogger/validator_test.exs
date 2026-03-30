defmodule TeslaMate.Import.TeslaLogger.ValidatorTest do
  use ExUnit.Case, async: true

  alias TeslaMate.Import.TeslaLogger.Validator
  alias TeslaMate.Import.TeslaLogger.Validator.ValidationError

  describe "validate_positions/1" do
    test "accepts valid positions" do
      positions = [
        %{date: ~U[2023-06-15 12:00:00Z], latitude: Decimal.new(52), longitude: Decimal.new(13),
          battery_level: 72, speed: 65, odometer: 42000.0},
        %{date: ~U[2023-06-15 12:01:00Z], latitude: Decimal.new(52), longitude: Decimal.new(13),
          battery_level: 71, speed: 60, odometer: 42001.0}
      ]

      {valid, errors} = Validator.validate_positions(positions)
      assert length(valid) == 2
      hard_errors = Enum.filter(errors, &(&1.severity == :error))
      assert hard_errors == []
    end

    test "rejects positions without required fields" do
      positions = [
        %{date: nil, latitude: Decimal.new(52), longitude: Decimal.new(13),
          battery_level: 72, speed: 65, odometer: 42000.0}
      ]

      {valid, errors} = Validator.validate_positions(positions)
      assert length(valid) == 0
      assert Enum.any?(errors, &(&1.field == :date and &1.severity == :error))
    end

    test "warns about out-of-range battery levels" do
      positions = [
        %{date: ~U[2023-06-15 12:00:00Z], latitude: Decimal.new(52), longitude: Decimal.new(13),
          battery_level: 105, speed: 0, odometer: 42000.0}
      ]

      {valid, errors} = Validator.validate_positions(positions)
      assert length(valid) == 1
      assert Enum.any?(errors, &(&1.field == :battery_level and &1.severity == :warning))
    end

    test "warns about invalid coordinates" do
      positions = [
        %{date: ~U[2023-06-15 12:00:00Z], latitude: Decimal.new(95), longitude: Decimal.new(13),
          battery_level: 72, speed: 0, odometer: 42000.0}
      ]

      {valid, errors} = Validator.validate_positions(positions)
      assert length(valid) == 1
      assert Enum.any?(errors, &(&1.field == :latitude and &1.severity == :warning))
    end
  end

  describe "validate_drives/1" do
    test "accepts valid drives" do
      drives = [
        %{start_date: ~U[2023-06-15 12:00:00Z], end_date: ~U[2023-06-15 12:30:00Z], speed_max: 130},
        %{start_date: ~U[2023-06-15 14:00:00Z], end_date: ~U[2023-06-15 14:45:00Z], speed_max: 100}
      ]

      {valid, errors} = Validator.validate_drives(drives)
      assert length(valid) == 2
      hard_errors = Enum.filter(errors, &(&1.severity == :error))
      assert hard_errors == []
    end

    test "warns about drives where start >= end" do
      drives = [
        %{start_date: ~U[2023-06-15 13:00:00Z], end_date: ~U[2023-06-15 12:00:00Z], speed_max: 50}
      ]

      {valid, errors} = Validator.validate_drives(drives)
      assert length(valid) == 1
      assert Enum.any?(errors, &(&1.field == :start_date and &1.severity == :warning))
    end

    test "warns about overlapping drives" do
      drives = [
        %{start_date: ~U[2023-06-15 12:00:00Z], end_date: ~U[2023-06-15 13:00:00Z], speed_max: 100},
        %{start_date: ~U[2023-06-15 12:30:00Z], end_date: ~U[2023-06-15 13:30:00Z], speed_max: 80}
      ]

      {_valid, errors} = Validator.validate_drives(drives)
      assert Enum.any?(errors, &(&1.message =~ "Overlap"))
    end
  end

  describe "validate_charges/1" do
    test "accepts valid charges" do
      charges = [
        %{date: ~U[2023-06-15 20:00:00Z], battery_level: 45,
          charge_energy_added: Decimal.new(10), charger_power: 11, charger_phases: 3}
      ]

      {valid, errors} = Validator.validate_charges(charges)
      assert length(valid) == 1
      hard_errors = Enum.filter(errors, &(&1.severity == :error))
      assert hard_errors == []
    end

    test "warns about negative charge_energy_added" do
      charges = [
        %{date: ~U[2023-06-15 20:00:00Z], battery_level: 45,
          charge_energy_added: Decimal.new(-5), charger_power: 11, charger_phases: 1}
      ]

      {_valid, errors} = Validator.validate_charges(charges)
      assert Enum.any?(errors, &(&1.field == :charge_energy_added and &1.severity == :warning))
    end
  end

  describe "validate_charging_processes/1" do
    test "accepts valid processes" do
      processes = [
        %{start_date: ~U[2023-06-15 20:00:00Z], end_date: ~U[2023-06-15 23:00:00Z],
          charge_energy_added: Decimal.new(45)}
      ]

      {valid, errors} = Validator.validate_charging_processes(processes)
      assert length(valid) == 1
    end

    test "warns about overlapping processes" do
      processes = [
        %{start_date: ~U[2023-06-15 20:00:00Z], end_date: ~U[2023-06-15 23:00:00Z],
          charge_energy_added: Decimal.new(45)},
        %{start_date: ~U[2023-06-15 22:00:00Z], end_date: ~U[2023-06-16 01:00:00Z],
          charge_energy_added: Decimal.new(30)}
      ]

      {_valid, errors} = Validator.validate_charging_processes(processes)
      assert Enum.any?(errors, &(&1.message =~ "Overlap"))
    end
  end

  describe "format_warnings/1" do
    test "formats warning errors as strings" do
      errors = [
        %ValidationError{table: "positions", row_id: 5, field: :battery_level, message: "value 105 outside range [0, 100]", severity: :warning},
        %ValidationError{table: "positions", row_id: 10, field: :date, message: "required field is nil", severity: :error}
      ]

      warnings = Validator.format_warnings(errors)
      assert length(warnings) == 1
      assert hd(warnings) =~ "battery_level"
    end
  end
end
