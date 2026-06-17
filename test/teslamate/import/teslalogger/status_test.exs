defmodule TeslaMate.Import.TeslaLogger.StatusTest do
  use ExUnit.Case, async: true

  alias TeslaMate.Import.TeslaLogger.Status

  test "initial/0 creates status with all steps pending" do
    status = Status.initial()
    assert status.state == :idle
    assert length(status.steps) == 9
    assert Enum.all?(status.steps, &(&1.status == :pending))
  end

  test "start_step/3 marks step as running" do
    status = Status.initial() |> Status.start_step(:positions, 50000)
    step = Enum.find(status.steps, &(&1.name == :positions))
    assert step.status == :running
    assert step.total == 50000
    assert status.current_step == :positions
  end

  test "update_step_progress/3 updates imported count" do
    status =
      Status.initial()
      |> Status.start_step(:positions, 50000)
      |> Status.update_step_progress(:positions, 25000)

    step = Enum.find(status.steps, &(&1.name == :positions))
    assert step.imported == 25000
  end

  test "complete_step/2 marks step as complete" do
    status =
      Status.initial()
      |> Status.start_step(:positions, 50000)
      |> Status.complete_step(:positions)

    step = Enum.find(status.steps, &(&1.name == :positions))
    assert step.status == :complete
    assert step.imported == 50000
  end

  test "fail_step/3 marks step as error" do
    status =
      Status.initial()
      |> Status.start_step(:positions, 50000)
      |> Status.fail_step(:positions, "connection lost")

    step = Enum.find(status.steps, &(&1.name == :positions))
    assert step.status == {:error, "connection lost"}
    assert status.state == {:error, "connection lost"}
  end

  test "add_warning/2 accumulates warnings" do
    status =
      Status.initial()
      |> Status.add_warning("test warning 1")
      |> Status.add_warning("test warning 2")

    assert length(status.warnings) == 2
  end

  describe "progress_fraction/1" do
    test "is 0 without a known total" do
      assert Status.progress_fraction(Status.initial()) == 0.0
    end

    test "counts map+insert steps twice (mapping is half, inserting the other half)" do
      # positions: 100 records → 200 work units of a 200 total
      base = %{Status.initial() | progress_total: 200} |> Status.start_step(:positions, 100)

      mapping =
        base
        |> Status.set_phase(:positions, :mapping)
        |> Status.update_step_progress(:positions, 50)

      assert Status.progress_fraction(mapping) == 0.25

      mapped =
        base
        |> Status.set_phase(:positions, :inserting)
        |> Status.update_step_progress(:positions, 0)

      assert Status.progress_fraction(mapped) == 0.5

      inserting =
        base
        |> Status.set_phase(:positions, :inserting)
        |> Status.update_step_progress(:positions, 50)

      assert Status.progress_fraction(inserting) == 0.75
    end

    test "is monotonic across the mapping→inserting transition" do
      base = %{Status.initial() | progress_total: 200} |> Status.start_step(:positions, 100)

      end_of_mapping =
        base
        |> Status.set_phase(:positions, :mapping)
        |> Status.update_step_progress(:positions, 100)

      start_of_inserting =
        base
        |> Status.set_phase(:positions, :inserting)
        |> Status.update_step_progress(:positions, 0)

      assert Status.progress_fraction(end_of_mapping) == 0.5
      assert Status.progress_fraction(start_of_inserting) == 0.5
    end

    test "completing a step commits its full work" do
      status =
        %{Status.initial() | progress_total: 200}
        |> Status.start_step(:positions, 100)
        |> Status.complete_step(:positions)

      assert status.progress_committed == 200
      assert Status.progress_fraction(status) == 1.0
    end

    test "insert-only steps count their records once" do
      assert Status.step_work(:states, 100) == 100
      assert Status.step_work(:positions, 100) == 200
      assert Status.step_work(:cars, 100) == 0
    end
  end
end
