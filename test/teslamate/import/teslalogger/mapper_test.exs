defmodule TeslaMate.Import.TeslaLogger.MapperTest do
  use ExUnit.Case, async: true

  alias TeslaMate.Import.TeslaLogger.Mapper

  @timezone "Europe/Berlin"

  describe "map_position/2" do
    test "maps all fields correctly" do
      row = %{
        "Datum" => ~N[2023-06-15 14:30:00],
        "lat" => 52.5200,
        "lng" => 13.4050,
        "speed" => 65,
        "power" => -15,
        "odometer" => 42000.5,
        "altitude" => 35,
        "battery_level" => 72,
        "inside_temp" => 22.5,
        "outside_temp" => 18.3,
        "battery_heater" => 0,
        "battery_range_km" => 280.5,
        "ideal_battery_range_km" => 295.0
      }

      result = Mapper.map_position(row, @timezone)

      assert %DateTime{} = result.date
      assert result.latitude == Decimal.from_float(52.5200)
      assert result.longitude == Decimal.from_float(13.4050)
      assert result.speed == 65
      assert result.power == -15
      assert result.odometer == 42000.5
      assert result.elevation == 35
      assert result.battery_level == 72
      assert result.inside_temp == Decimal.from_float(22.5)
      assert result.outside_temp == Decimal.from_float(18.3)
      assert result.battery_heater == false
      assert result.ideal_battery_range_km == Decimal.from_float(295.0)
      assert result.rated_battery_range_km == Decimal.from_float(280.5)
    end

    test "handles nil values" do
      row = %{
        "Datum" => ~N[2023-06-15 14:30:00],
        "lat" => 52.5,
        "lng" => 13.4,
        "speed" => nil,
        "power" => nil,
        "odometer" => nil,
        "altitude" => nil,
        "battery_level" => nil,
        "inside_temp" => nil,
        "outside_temp" => nil,
        "battery_heater" => nil,
        "battery_range_km" => nil,
        "ideal_battery_range_km" => nil
      }

      result = Mapper.map_position(row, @timezone)

      assert result.speed == nil
      assert result.power == nil
      assert result.odometer == nil
      assert result.elevation == nil
    end

    test "converts local time to UTC" do
      # 14:30 Berlin (CEST = UTC+2) -> 12:30 UTC
      row = %{
        "Datum" => ~N[2023-06-15 14:30:00],
        "lat" => 52.5,
        "lng" => 13.4,
        "speed" => nil, "power" => nil, "odometer" => nil,
        "altitude" => nil, "battery_level" => nil,
        "inside_temp" => nil, "outside_temp" => nil,
        "battery_heater" => nil, "battery_range_km" => nil,
        "ideal_battery_range_km" => nil
      }

      result = Mapper.map_position(row, @timezone)
      assert result.date.hour == 12
      assert result.date.time_zone == "Etc/UTC"
    end
  end

  describe "map_drive/2" do
    test "maps drive fields" do
      row = %{
        "StartDate" => ~N[2023-06-15 14:00:00],
        "EndDate" => ~N[2023-06-15 14:45:00],
        "outside_temp_avg" => 18.5,
        "speed_max" => 130,
        "power_max" => 80,
        "power_min" => -50
      }

      result = Mapper.map_drive(row, @timezone)

      assert %DateTime{} = result.start_date
      assert %DateTime{} = result.end_date
      assert result.outside_temp_avg == Decimal.from_float(18.5)
      assert result.speed_max == 130
      assert result.power_max == 80
      assert result.power_min == -50
    end
  end

  describe "enrich_drive/2" do
    test "enriches drive with position data" do
      drive = %{
        start_date: ~U[2023-06-15 12:00:00Z],
        end_date: ~U[2023-06-15 12:45:00Z]
      }

      positions = [
        %{odometer: 42000.0, ideal_battery_range_km: Decimal.new(300), rated_battery_range_km: Decimal.new(280), inside_temp: Decimal.new(22), outside_temp: nil},
        %{odometer: 42025.0, ideal_battery_range_km: Decimal.new(290), rated_battery_range_km: Decimal.new(270), inside_temp: Decimal.new(23), outside_temp: nil},
        %{odometer: 42050.0, ideal_battery_range_km: Decimal.new(270), rated_battery_range_km: Decimal.new(250), inside_temp: Decimal.new(24), outside_temp: nil}
      ]

      result = Mapper.enrich_drive(drive, positions)

      assert result.start_km == 42000.0
      assert result.end_km == 42050.0
      assert result.distance == 50.0
      assert result.duration_min == 45
      assert result.start_ideal_range_km == Decimal.new(300)
      assert result.end_ideal_range_km == Decimal.new(270)
    end

    test "handles empty positions" do
      drive = %{start_date: ~U[2023-06-15 12:00:00Z], end_date: ~U[2023-06-15 12:45:00Z]}
      result = Mapper.enrich_drive(drive, [])
      assert result == drive
    end
  end

  describe "map_charge/2" do
    test "maps charge fields" do
      row = %{
        "Datum" => ~N[2023-06-15 20:00:00],
        "battery_level" => 45,
        "usable_battery_level" => 43,
        "charge_energy_added" => 12.5,
        "charger_power" => 11,
        "ideal_battery_range_km" => 180.0,
        "rated_battery_range_km" => 175.0,
        "charger_voltage" => 230,
        "charger_phases" => 3,
        "charger_actual_current" => 16,
        "outside_temp" => 15.0,
        "charger_pilot_current" => 16,
        "battery_heater" => false
      }

      result = Mapper.map_charge(row, @timezone)

      assert result.battery_level == 45
      assert result.usable_battery_level == 43
      assert result.charge_energy_added == Decimal.from_float(12.5)
      assert result.charger_power == 11
      assert result.ideal_battery_range_km == Decimal.from_float(180.0)
      assert result.rated_battery_range_km == Decimal.from_float(175.0)
      assert result.charger_voltage == 230
      assert result.charger_phases == 3
    end
  end

  describe "map_charging_process/2" do
    test "maps charging process fields" do
      row = %{
        "StartDate" => ~N[2023-06-15 20:00:00],
        "EndDate" => ~N[2023-06-15 23:30:00],
        "charge_energy_added" => 45.2,
        "cost_total" => 15.60
      }

      result = Mapper.map_charging_process(row, @timezone)

      assert %DateTime{} = result.start_date
      assert %DateTime{} = result.end_date
      assert result.charge_energy_added == Decimal.from_float(45.2)
      assert result.cost == Decimal.from_float(15.60)
      assert result.duration_min == 210
    end
  end

  describe "map_state/2" do
    test "maps known states" do
      for {input, expected} <- [
            {"online", :online},
            {"offline", :offline},
            {"asleep", :asleep},
            {"sleeping", :asleep},
            {"driving", :online},
            {"charging", :online}
          ] do
        row = %{"StartDate" => ~N[2023-06-15 12:00:00], "EndDate" => ~N[2023-06-15 13:00:00], "state" => input}
        result = Mapper.map_state(row, @timezone)
        assert result.state == expected, "Expected #{input} to map to #{expected}"
      end
    end
  end

  describe "add_update_end_dates/1" do
    test "adds end_date from next update" do
      updates = [
        %{start_date: ~U[2023-01-01 00:00:00Z], version: "2023.1.1"},
        %{start_date: ~U[2023-03-01 00:00:00Z], version: "2023.6.8"},
        %{start_date: ~U[2023-06-01 00:00:00Z], version: "2023.20.4"}
      ]

      result = Mapper.add_update_end_dates(updates)

      assert Enum.at(result, 0).end_date == ~U[2023-03-01 00:00:00Z]
      assert Enum.at(result, 1).end_date == ~U[2023-06-01 00:00:00Z]
      assert Enum.at(result, 2) |> Map.get(:end_date) == nil
    end
  end
end
