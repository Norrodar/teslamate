defmodule TeslaMate.Import.TeslaLogger.Status do
  @moduledoc false

  @type step_status :: :pending | :running | :complete | {:error, term()}

  @type step :: %{
          name: atom(),
          status: step_status(),
          total: non_neg_integer(),
          imported: non_neg_integer()
        }

  @type state ::
          :idle
          | :connecting
          | :running
          | :complete
          | {:error, term()}

  @type t :: %__MODULE__{
          state: state(),
          current_step: atom() | nil,
          steps: [step()],
          warnings: [String.t()],
          car_count: non_neg_integer()
        }

  defstruct state: :idle,
            current_step: nil,
            steps: [],
            warnings: [],
            car_count: 0

  @step_names [
    :cars,
    :positions,
    :drives,
    :charges,
    :charging_processes,
    :states,
    :updates,
    :geocoding,
    :validation
  ]

  def initial do
    steps =
      Enum.map(@step_names, fn name ->
        %{name: name, status: :pending, total: 0, imported: 0}
      end)

    %__MODULE__{steps: steps}
  end

  def set_state(%__MODULE__{} = status, state) do
    %{status | state: state}
  end

  def start_step(%__MODULE__{} = status, step_name, total \\ 0) do
    steps =
      Enum.map(status.steps, fn
        %{name: ^step_name} = step -> %{step | status: :running, total: total}
        step -> step
      end)

    %{status | current_step: step_name, steps: steps}
  end

  def update_step_progress(%__MODULE__{} = status, step_name, imported) do
    steps =
      Enum.map(status.steps, fn
        %{name: ^step_name} = step -> %{step | imported: imported}
        step -> step
      end)

    %{status | steps: steps}
  end

  def complete_step(%__MODULE__{} = status, step_name) do
    steps =
      Enum.map(status.steps, fn
        %{name: ^step_name} = step -> %{step | status: :complete, imported: step.total}
        step -> step
      end)

    %{status | steps: steps}
  end

  def fail_step(%__MODULE__{} = status, step_name, reason) do
    steps =
      Enum.map(status.steps, fn
        %{name: ^step_name} = step -> %{step | status: {:error, reason}}
        step -> step
      end)

    %{status | steps: steps, state: {:error, reason}}
  end

  def add_warning(%__MODULE__{} = status, warning) do
    %{status | warnings: [warning | status.warnings]}
  end

  def add_warnings(%__MODULE__{} = status, new_warnings) do
    %{status | warnings: new_warnings ++ status.warnings}
  end
end
