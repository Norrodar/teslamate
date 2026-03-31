defmodule TeslaMateWeb.ImportLive.TeslaLogger do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Import.TeslaLogger, as: TLImport
  alias TeslaMate.Import.TeslaLogger.Status

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, %{"settings" => _}, socket) do
    if TLImport.enabled?() do
      if connected?(socket) do
        :ok = TLImport.subscribe()
        # Trigger preflight to discover VINs
        :ok = TLImport.preflight()
      end

      status = TLImport.get_status()

      socket =
        socket
        |> assign(status: status)
        |> assign(page_title: gettext("TeslaLogger Import"))
        |> assign(car_vin: "")
        |> assign(car_eid: "")
        |> assign(car_vid: "")
        |> assign(import_mode: "clean")
        |> assign(show_destructive_warning: false)

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("start_import", _params, socket) do
    mode = socket.assigns.import_mode

    # Mode C requires confirmation
    if mode == "merge_tl" do
      {:noreply, assign(socket, show_destructive_warning: true)}
    else
      do_start_import(socket)
    end
  end

  def handle_event("confirm_destructive", _params, socket) do
    socket = assign(socket, show_destructive_warning: false)
    do_start_import(socket)
  end

  def handle_event("cancel_destructive", _params, socket) do
    {:noreply, assign(socket, show_destructive_warning: false)}
  end

  def handle_event("select_mode", %{"value" => mode}, socket) do
    {:noreply, assign(socket, import_mode: mode)}
  end

  def handle_event("update_car_vin", %{"value" => vin}, socket) do
    {:noreply, assign(socket, car_vin: vin)}
  end

  def handle_event("update_car_eid", %{"value" => eid}, socket) do
    {:noreply, assign(socket, car_eid: eid)}
  end

  def handle_event("update_car_vid", %{"value" => vid}, socket) do
    {:noreply, assign(socket, car_vid: vid)}
  end

  @impl true
  def handle_info({:teslalogger_import, %Status{} = status}, socket) do
    {:noreply, assign(socket, status: status)}
  end

  defp do_start_import(socket) do
    car_mapping =
      case {socket.assigns.car_vin, socket.assigns.car_eid, socket.assigns.car_vid} do
        {"", "", ""} ->
          %{}

        {vin, eid, vid} ->
          eid_int = safe_to_integer(eid)
          vid_int = safe_to_integer(vid)
          %{1 => %{vin: if(vin != "", do: vin), eid: eid_int, vid: vid_int}}
      end

    mode =
      case socket.assigns.import_mode do
        "clean" -> :clean
        "merge_tm" -> :merge_tm_priority
        "merge_tl" -> :merge_tl_priority
        _ -> :clean
      end

    case TLImport.run(car_mapping, mode: mode) do
      :ok ->
        %Status{} = current_status = socket.assigns.status
        {:noreply, assign(socket, status: %{current_status | state: :running})}

      {:error, :already_running} ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="breadcrumb" aria-label="breadcrumbs">
      <ul>
        <li><.link navigate={~p"/"}><%= gettext("Home") %></.link></li>
        <li class="is-active"><.link navigate="">TeslaLogger Import</.link></li>
      </ul>
    </nav>

    <h2 class="title is-4">TeslaLogger Import</h2>

    <%= if @status.state == :idle do %>
      <div class="box">
        <h3 class="title is-5"><%= gettext("Car Configuration") %></h3>

        <%= if @status.mysql_car_info != [] do %>
          <div class="mb-4">
            <%= for car_info <- @status.mysql_car_info do %>
              <%= if car_info["vin"] && car_info["vin"] != "" do %>
                <div class="notification is-success is-light py-2 px-3 mb-2">
                  <span class="icon"><span class="mdi mdi-check-circle"></span></span>
                  <strong>Car <%= car_info["id"] %></strong>: VIN from TeslaLogger: <code><%= car_info["vin"] %></code>
                  <%= if car_info["display_name"] do %>
                    (<%= car_info["display_name"] %>)
                  <% end %>
                </div>
              <% else %>
                <div class="notification is-warning is-light py-2 px-3 mb-2">
                  <span class="icon"><span class="mdi mdi-alert"></span></span>
                  <strong>Car <%= car_info["id"] %></strong>: No VIN found in TeslaLogger
                  <%= if car_info["display_name"] do %>
                    (<%= car_info["display_name"] %>)
                  <% end %>
                  — <strong>Please enter VIN below!</strong>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>

        <div class="field">
          <label class="label">VIN <span class="has-text-grey-light has-text-weight-normal">— optional, recommended</span></label>
          <div class="control">
            <input class="input" type="text" placeholder="5YJ3E1EA1LF000000"
                   value={@car_vin} phx-keyup="update_car_vin" phx-debounce="300" />
          </div>
          <p class="help">Overrides the VIN from TeslaLogger if present.</p>
        </div>

        <div class="columns">
          <div class="column">
            <div class="field">
              <label class="label">EID (Tesla API ID) <span class="has-text-grey-light has-text-weight-normal">— optional</span></label>
              <div class="control">
                <input class="input" type="text" placeholder="1234567890"
                       value={@car_eid} phx-keyup="update_car_eid" phx-debounce="300" />
              </div>
            </div>
          </div>
          <div class="column">
            <div class="field">
              <label class="label">VID (Vehicle ID) <span class="has-text-grey-light has-text-weight-normal">— optional</span></label>
              <div class="control">
                <input class="input" type="text" placeholder="1234567891"
                       value={@car_vid} phx-keyup="update_car_vid" phx-debounce="300" />
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="box">
        <h3 class="title is-5"><%= gettext("Import Mode") %></h3>

        <div class="field">
          <label class="radio mb-3" style="display: block;">
            <input type="radio" name="import_mode" value="clean"
                   checked={@import_mode == "clean"}
                   phx-click="select_mode" phx-value-value="clean" />
            <strong>Clean database</strong>
            <p class="has-text-grey ml-5">
              Expects an empty TeslaMate database for this vehicle.
              Aborts if data already exists.
            </p>
          </label>

          <label class="radio mb-3" style="display: block;">
            <input type="radio" name="import_mode" value="merge_tm"
                   checked={@import_mode == "merge_tm"}
                   phx-click="select_mode" phx-value-value="merge_tm" />
            <strong>Merge (TeslaMate priority)</strong>
            <p class="has-text-grey ml-5">
              Only imports data for time periods where TeslaMate has no data.
              Existing TeslaMate data remains unchanged.
            </p>
          </label>

          <label class="radio mb-3" style="display: block;">
            <input type="radio" name="import_mode" value="merge_tl"
                   checked={@import_mode == "merge_tl"}
                   phx-click="select_mode" phx-value-value="merge_tl" />
            <strong>Merge (TeslaLogger priority)</strong>
            <p class="has-text-danger ml-5">
              <span class="icon"><span class="mdi mdi-alert"></span></span>
              Deletes overlapping TeslaMate data and replaces it with TeslaLogger data!
            </p>
          </label>
        </div>

        <div class="field mt-5">
          <div class="control">
            <button class="button is-success is-fullwidth" phx-click="start_import"
                    phx-disable-with="Starting...">
              <%= gettext("Start Import") %>
            </button>
          </div>
        </div>
      </div>
    <% end %>

    <%= if @show_destructive_warning do %>
      <div class="modal is-active">
        <div class="modal-background" phx-click="cancel_destructive"></div>
        <div class="modal-card">
          <header class="modal-card-head has-background-danger">
            <p class="modal-card-title has-text-white">
              <span class="icon"><span class="mdi mdi-alert"></span></span>
              Warning: Destructive Import
            </p>
          </header>
          <section class="modal-card-body">
            <p class="mb-3">
              <strong>This mode deletes existing TeslaMate data</strong> in time periods
              that overlap with TeslaLogger data.
            </p>
            <p class="has-text-danger">
              This cannot be undone! Make sure you have a backup.
            </p>
          </section>
          <footer class="modal-card-foot">
            <button class="button" phx-click="cancel_destructive">Cancel</button>
            <button class="button is-danger" phx-click="confirm_destructive">
              Yes, start import
            </button>
          </footer>
        </div>
      </div>
    <% end %>

    <%= if @status.state != :idle do %>
      <div class="box">
        <h3 class="title is-5"><%= gettext("Import Progress") %></h3>

        <%= if @status.car_count > 0 do %>
          <p class="mb-2">
            Found <strong><%= @status.car_count %></strong> car(s) in TeslaLogger
          </p>
        <% end %>

        <%= if @status.import_mode != :clean do %>
          <p class="mb-4">
            <span class="tag is-info is-light"><%= mode_label(@status.import_mode) %></span>
          </p>
        <% end %>

        <table class="table is-fullwidth is-hoverable">
          <thead>
            <tr>
              <th><%= gettext("Step") %></th>
              <th><%= gettext("Status") %></th>
              <th><%= gettext("Phase") %></th>
              <th><%= gettext("Progress") %></th>
              <th><%= gettext("Imported") %></th>
            </tr>
          </thead>
          <tbody>
            <%= for step <- @status.steps do %>
              <tr>
                <td><%= step_label(step.name) %></td>
                <td>
                  <span>
                    <%= case step.status do %>
                      <% :pending -> %>
                        <span class="icon has-text-grey-light">
                          <span class="mdi mdi-clock-outline"></span>
                        </span>
                      <% :running -> %>
                        <span class="is-loading"></span>
                      <% :complete -> %>
                        <span class="icon has-text-success">
                          <span class="mdi mdi-check-bold"></span>
                        </span>
                      <% {:error, reason} -> %>
                        <span class="icon has-text-danger" title={inspect(reason)}>
                          <span class="mdi mdi-alert-circle"></span>
                        </span>
                    <% end %>
                  </span>
                </td>
                <td>
                  <span class={phase_color(step.phase)}>
                    <%= phase_label(step.phase) %>
                  </span>
                </td>
                <td style="font-variant-numeric: tabular-nums;">
                  <%= format_progress(step) %>
                </td>
                <td style="font-variant-numeric: tabular-nums;">
                  <%= if step.status == :complete and step.total > 0 do %>
                    <strong><%= format_number(step.imported) %></strong>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>

    <%= if @status.state == :complete do %>
      <div class="notification is-success">
        <strong>Import complete!</strong>
        Geocoding will continue in the background. Check the Grafana dashboards to verify the imported data.
      </div>
    <% end %>

    <%= if match?({:error, _}, @status.state) do %>
      <div class="notification is-danger">
        <strong>Import failed:</strong>
        <code><%= inspect(elem(@status.state, 1), pretty: true) %></code>
      </div>
    <% end %>

    <%= if @status.warnings != [] do %>
      <div class="box mt-4">
        <h3 class="title is-5"><%= gettext("Validation Warnings") %></h3>
        <div class="content" style="max-height: 400px; overflow-y: auto;">
          <ul>
            <%= for warning <- Enum.take(@status.warnings, 50) do %>
              <li class="has-text-warning-dark"><%= warning %></li>
            <% end %>
            <%= if length(@status.warnings) > 50 do %>
              <li>... and <%= length(@status.warnings) - 50 %> more</li>
            <% end %>
          </ul>
        </div>
      </div>
    <% end %>
    """
  end

  ## Helpers

  defp safe_to_integer(""), do: nil

  defp safe_to_integer(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp step_label(name) do
    case name do
      :cars -> gettext("Cars")
      :positions -> gettext("Positions")
      :drives -> gettext("Drives")
      :charges -> gettext("Charges")
      :charging_processes -> gettext("Charging Sessions")
      :states -> gettext("States")
      :updates -> gettext("Updates")
      :geocoding -> gettext("Geocoding")
      :validation -> gettext("Validation")
      _ -> Atom.to_string(name)
    end
  end

  defp mode_label(:clean), do: "Clean database"
  defp mode_label(:merge_tm_priority), do: "Merge (TeslaMate priority)"
  defp mode_label(:merge_tl_priority), do: "Merge (TeslaLogger priority)"
  defp mode_label(_), do: ""

  defp phase_label(:pending), do: ""
  defp phase_label(:reading), do: gettext("Reading MySQL…")
  defp phase_label(:mapping), do: gettext("Mapping…")
  defp phase_label(:validating), do: gettext("Validating…")
  defp phase_label(:filtering), do: gettext("Filtering overlaps…")
  defp phase_label(:deleting), do: gettext("Deleting overlaps…")
  defp phase_label(:inserting), do: gettext("Inserting…")
  defp phase_label(:done), do: gettext("Done")
  defp phase_label(_), do: ""

  defp phase_color(:reading), do: "has-text-info"
  defp phase_color(:mapping), do: "has-text-info"
  defp phase_color(:validating), do: "has-text-warning"
  defp phase_color(:filtering), do: "has-text-warning"
  defp phase_color(:deleting), do: "has-text-danger"
  defp phase_color(:inserting), do: "has-text-primary"
  defp phase_color(:done), do: "has-text-success"
  defp phase_color(_), do: ""

  defp format_progress(step) do
    if step.total > 0 do
      "#{format_number(step.imported)}/#{format_number(step.total)}"
    else
      ""
    end
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join("'")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)
end
