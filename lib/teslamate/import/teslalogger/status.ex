defmodule TeslaMate.Import.TeslaLogger.Status do
  @moduledoc false

  @type step_status :: :pending | :running | :complete | {:error, term()}

  @type import_mode :: :clean | :merge_tm_priority | :merge_tl_priority

  @type phase ::
          :pending
          | :reading
          | :mapping
          | :merging_tpms
          | :filtering_idle
          | :validating
          | :filtering
          | :deleting
          | :inserting
          | :done

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

  @type preview :: nil | :loading | {:ok, [map()]} | {:error, String.t()}

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
          geocoding_lookups: non_neg_integer(),
          preview: preview(),
          progress_total: non_neg_integer(),
          progress_committed: non_neg_integer(),
          started_at: DateTime.t() | nil
        }

  defstruct state: :idle,
            current_step: nil,
            steps: [],
            preflight_steps: [],
            warnings: [],
            car_count: 0,
            import_mode: :clean,
            mysql_car_info: [],
            tm_has_data: false,
            geocoding_lookups: 0,
            preview: nil,
            # Overall progress is counted in "work units": every record mapped/inserted
            # is one unit. progress_total is the pre-counted sum over all selected cars;
            # progress_committed accumulates monotonically as steps complete.
            progress_total: 0,
            progress_committed: 0,
            started_at: nil

  # Steps with a heavy mapping phase: their records count once for mapping and once
  # for inserting, so a long mapping phase moves the bar like the user expects.
  @map_insert_steps [:positions, :drives, :charging_processes]
  @insert_only_steps [:charges, :states, :updates]

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

  @preflight_step_names [
    :connecting,
    :validating_timezone,
    :checking_schema,
    :reading_source,
    :checking_target
  ]

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

  def complete_step(%__MODULE__{} = status, step_name, imported \\ nil) do
    step = Enum.find(status.steps, &(&1.name == step_name))

    steps =
      Enum.map(status.steps, fn
        %{name: ^step_name} = s ->
          %{s | status: :complete, phase: :done, imported: imported || s.total}

        s ->
          s
      end)

    # Commit this step's full work to the monotonic overall counter.
    committed = status.progress_committed + step_work(step_name, (step && step.total) || 0)
    %{status | steps: steps, progress_committed: committed}
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

  # Overall progress / ETA

  def set_progress_total(%__MODULE__{} = status, total) do
    %{status | progress_total: total}
  end

  def set_started_at(%__MODULE__{} = status, %DateTime{} = at) do
    %{status | started_at: at}
  end

  @doc """
  Work units a step contributes once finished. map+insert steps count their
  records twice (mapping + inserting); insert-only steps once; the rest (cars,
  geocoding, validation) carry no per-record work.
  """
  def step_work(name, total) when name in @map_insert_steps, do: total * 2
  def step_work(name, total) when name in @insert_only_steps, do: total
  def step_work(_name, _total), do: 0

  @doc """
  Overall import progress as a 0.0..1.0 fraction: committed work of finished
  steps plus the live contribution of the running step. Monotonic.
  """
  def progress_fraction(%__MODULE__{progress_total: total}) when total <= 0, do: 0.0

  def progress_fraction(%__MODULE__{} = status) do
    live =
      case Enum.find(status.steps, &(&1.status == :running)) do
        nil -> 0.0
        step -> step_work(step.name, step.total) * live_phase_fraction(step)
      end

    min((status.progress_committed + live) / status.progress_total, 1.0)
  end

  # Monotonic 0.0..1.0 share of a running step, aware of its phase so the
  # mapping→inserting transition doesn't make the bar jump back.
  defp live_phase_fraction(%{name: name} = step) when name in @map_insert_steps do
    case step.phase do
      :mapping ->
        0.5 * ratio(step.imported, step.total)

      # All post-mapping, pre-insert phases: mapping done, inserting not started.
      phase when phase in [:merging_tpms, :filtering_idle, :validating, :filtering, :deleting] ->
        0.5

      :inserting ->
        0.5 + 0.5 * ratio(step.imported, step.total)

      :done ->
        1.0

      _ ->
        0.0
    end
  end

  defp live_phase_fraction(%{} = step) do
    case step.phase do
      :inserting -> ratio(step.imported, step.total)
      :done -> 1.0
      _ -> 0.0
    end
  end

  defp ratio(_imported, total) when total <= 0, do: 0.0
  defp ratio(imported, total), do: min(imported / total, 1.0)

  def set_preview(%__MODULE__{} = status, preview) do
    %{status | preview: preview}
  end

  def add_warning(%__MODULE__{} = status, warning) do
    %{status | warnings: [warning | status.warnings]}
  end

  def add_warnings(%__MODULE__{} = status, new_warnings) do
    %{status | warnings: new_warnings ++ status.warnings}
  end
end
