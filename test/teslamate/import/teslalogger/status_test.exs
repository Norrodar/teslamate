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
end
