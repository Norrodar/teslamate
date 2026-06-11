defmodule TeslaMate.Import.TeslaLogger.Status do
  @moduledoc false

  @type step_status :: :pending | :running | :complete | {:error, term()}

  @type import_mode :: :clean | :merge_tm_priority | :merge_tl_priority

  @type phase :: :pending | :reading | :mapping | :validating | :filtering | :deleting | :inserting | :done

  @type preflight_step :: %{
          name: atom(),
          status: step_status(),
          detail: String.t() | nil
        }

  @type step :: %{
          name: atom(),
          status: step_status(),
          phase: phase(),
          total: non_neg_integer(),
          imported: non_neg_integer()
        }

  @type state ::
          :unconfigured
          | :idle
          | :preflight
          | :running
          | :complete
          | {:error, term()}

  @type t :: %__MODULE__{
          state: state(),
          current_step: atom() | nil,
          steps: [step()],
          preflight_steps: [preflight_step()],
          warnings: [String.t()],
          car_count: non_neg_integer(),
          import_mode: import_mode(),
          mysql_car_info: [map()],
          tm_has_data: boolean(),
          geocoding_lookups: non_neg_integer()
        }

  defstruct state: :unconfigured,
            current_step: nil,
            steps: [],
            preflight_steps: [],
            warnings: [],
            car_count: 0,
            import_mode: :clean,
            mysql_car_info: [],
            tm_has_data: false,
            geocoding_lookups: 0

  @step_names [
    :cars,
    :positions,
    :drives,
    :charging_processes,
    :charges,
    :states,
    :updates,
    :geocoding,
    :validation
  ]

  @preflight_step_names [:connecting, :validating_timezone, :checking_schema, :reading_source, :checking_target]

  def initial do
    steps =
      Enum.map(@step_names, fn name ->
        %{name: name, status: :pending, phase: :pending, total: 0, imported: 0}
      end)

    preflight_steps =
      Enum.map(@preflight_step_names, fn name ->
        %{name: name, status: :pending, detail: nil}
      end)

    %__MODULE__{steps: steps, preflight_steps: preflight_steps}
  end

  def set_state(%__MODULE__{} = status, state) do
    %{status | state: state}
  end

  # Preflight step helpers

  def update_preflight_step(%__MODULE__{} = status, step_name, new_status, detail \\ nil) do
    preflight_steps =
      Enum.map(status.preflight_steps, fn
        %{name: ^step_name} = step -> %{step | status: new_status, detail: detail}
        step -> step
      end)

    %{status | preflight_steps: preflight_steps}
  end

  # Import step helpers

  def start_step(%__MODULE__{} = status, step_name, total \\ 0) do
    steps =
      Enum.map(status.steps, fn
        %{name: ^step_name} = step -> %{step | status: :running, total: total}
        step -> step
      end)

    %{status | current_step: step_name, steps: steps}
  end

  def set_phase(%__MODULE__{} = status, step_name, phase) do
    steps =
      Enum.map(status.steps, fn
        %{name: ^step_name} = step -> %{step | phase: phase}
        step -> step
      end)

    %{status | steps: steps}
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
        %{name: ^step_name} = step -> %{step | status: :complete, phase: :done, imported: step.total}
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

  def set_geocoding_lookups(%__MODULE__{} = status, count) do
    %{status | geocoding_lookups: count}
  end

  def add_warning(%__MODULE__{} = status, warning) do
    %{status | warnings: [warning | status.warnings]}
  end

  def add_warnings(%__MODULE__{} = status, new_warnings) do
    %{status | warnings: new_warnings ++ status.warnings}
  end
end
