defmodule TeslaMate.Import.TeslaLogger.PreviewTest do
  use ExUnit.Case, async: true

  alias TeslaMate.Import.TeslaLogger.Preview

  @car_ok %{"id" => 1, "vin" => "5YJ3E1EA1LF000000", "display_name" => "Model 3"}
  @car_no_vin %{"id" => 2, "vin" => nil, "display_name" => "Model Y"}

  defp drive(attrs) do
    Map.merge(
      %{
        tl_id: 10,
        start_date_local: ~N[2023-06-15 14:30:00],
        start_date: ~U[2023-06-15 12:30:00Z],
        distance: 42.0,
        duration_min: 30
      },
      attrs
    )
  end

  defp charge(attrs) do
    Map.merge(
      %{
        tl_id: 20,
        start_date_local: ~N[2023-06-15 20:00:00],
        start_date: ~U[2023-06-15 18:00:00Z],
        charge_energy_added: Decimal.new("12.5"),
        start_battery_level: 45
      },
      attrs
    )
  end

  describe "detect_issues/3 — cars" do
    test "flags missing VIN as a blocking error" do
      [issue] = Preview.detect_issues(@car_no_vin, [], [])
      assert issue.severity == :error
      assert issue.ref == :car
    end

    test "no issue when VIN is present and sample is clean" do
      assert Preview.detect_issues(@car_ok, [drive(%{})], [charge(%{})]) == []
    end
  end

  describe "detect_issues/3 — drives" do
    test "flags nil distance as phantom drive" do
      [issue] = Preview.detect_issues(@car_ok, [drive(%{distance: nil})], [])
      assert issue.severity == :warning
      assert issue.ref == {:drive, 10}
      assert issue.message =~ "phantom drive"
    end

    test "flags non-positive distance as phantom drive" do
      [issue] = Preview.detect_issues(@car_ok, [drive(%{distance: 0.0})], [])
      assert issue.message =~ "no movement"
    end

    test "flags micro-movement (short distance and duration) as phantom drive" do
      [issue] = Preview.detect_issues(@car_ok, [drive(%{distance: 0.2, duration_min: 1})], [])
      assert issue.message =~ "phantom drive"
    end

    test "flags failed timezone conversion" do
      [issue] = Preview.detect_issues(@car_ok, [drive(%{start_date: nil})], [])
      assert issue.message =~ "timezone"
    end

    test "flags suspiciously long drive" do
      [issue] = Preview.detect_issues(@car_ok, [drive(%{distance: 3000.0})], [])
      assert issue.message =~ "odometer"
    end
  end

  describe "detect_issues/3 — charges" do
    test "flags ~0 kWh session as phantom" do
      [issue] =
        Preview.detect_issues(@car_ok, [], [charge(%{charge_energy_added: Decimal.new("0.05")})])

      assert issue.ref == {:charge, 20}
      assert issue.message =~ "phantom session"
    end

    test "flags nil energy as phantom" do
      [issue] = Preview.detect_issues(@car_ok, [], [charge(%{charge_energy_added: nil})])
      assert issue.message =~ "phantom session"
    end

    test "flags session without charge rows (nil SOC)" do
      [issue] = Preview.detect_issues(@car_ok, [], [charge(%{start_battery_level: nil})])
      assert issue.message =~ "no charge rows"
    end
  end
end
