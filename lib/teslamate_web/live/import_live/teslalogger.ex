defmodule TeslaMateWeb.ImportLive.TeslaLogger do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Import.TeslaLogger, as: TLImport
  alias TeslaMate.Import.TeslaLogger.Status

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, %{"settings" => _}, socket) do
    if TLImport.enabled?() do
      if connected?(socket), do: TLImport.subscribe()

      status = TLImport.get_status()
      env_config = Application.get_env(:teslamate, :teslalogger_import, [])

      socket =
        socket
        |> assign(status: status)
        |> assign(page_title: gettext("TeslaLogger Import"))
        |> assign(car_vin: "")
        |> assign(car_eid: "")
        |> assign(car_vid: "")
        |> assign(import_mode: "clean")
        |> assign(show_destructive_warning: false)
        |> assign(conn_host: env_config[:host] || "")
        |> assign(conn_port: to_string(env_config[:port] || "3306"))
        |> assign(conn_user: env_config[:username] || "")
        |> assign(conn_password: env_config[:password] || "")
        |> assign(conn_database: env_config[:database] || "teslalogger")
        |> assign(conn_timezone: env_config[:timezone] || "Europe/Berlin")

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("update_conn_field", %{"field" => field, "value" => value}, socket) do
    assign_key = String.to_existing_atom("conn_#{field}")
    {:noreply, assign(socket, assign_key, value)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("test_connection", _params, socket) do
    port =
      case Integer.parse(socket.assigns.conn_port) do
        {p, _} -> p
        :error -> 3306
      end

    params = [
      host: socket.assigns.conn_host,
      port: port,
      username: socket.assigns.conn_user,
      password: socket.assigns.conn_password,
      database: socket.assigns.conn_database,
      timezone: socket.assigns.conn_timezone
    ]

    :ok = TLImport.configure(params)
    :ok = TLImport.preflight()
    {:noreply, socket}
  end

  def handle_event("reset_connection", _params, socket) do
    :ok = TLImport.reset()
    {:noreply, socket}
  end

  def handle_event("start_import", _params, socket) do
    mode = socket.assigns.import_mode

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
    # Guard: clean only when no TM data, merge only when TM has data
    cond do
      mode == "clean" and socket.assigns.status.tm_has_data -> {:noreply, socket}
      mode in ["merge_tm", "merge_tl"] and not socket.assigns.status.tm_has_data -> {:noreply, socket}
      true -> {:noreply, assign(socket, import_mode: mode)}
    end
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

  def handle_event("apply_car_values", %{"car-id" => car_id_str}, socket) do
    car_id = String.to_integer(car_id_str)

    car_info =
      Enum.find(socket.assigns.status.mysql_car_info, fn c -> c["id"] == car_id end)

    if car_info do
      vin = car_info["vin"] || ""
      {:noreply, assign(socket, car_vin: vin)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:teslalogger_import, %Status{} = status}, socket) do
    # Auto-switch away from "clean" mode when TM has data (clean would be disabled)
    import_mode =
      if status.tm_has_data and socket.assigns.import_mode == "clean" do
        "merge_tm"
      else
        socket.assigns.import_mode
      end

    {:noreply, assign(socket, status: status, import_mode: import_mode)}
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

      {:error, _reason} ->
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

    <%!-- Step 1: Connection Form (shown when unconfigured or preflight failed before any import step) --%>
    <%= if @status.state == :unconfigured or
           (match?({:error, _}, @status.state) and @status.current_step == nil and
            not preflight_passed?(@status.preflight_steps)) do %>
      <div class="box mb-4">
        <h3 class="title is-5">Database Connection</h3>
        <p class="mb-4 has-text-grey">Enter the connection details for your TeslaLogger MySQL database.</p>

        <div class="columns">
          <div class="column is-two-thirds">
            <div class="field">
              <label class="label">Host</label>
              <div class="control">
                <input class="input" type="text" placeholder="localhost"
                       value={@conn_host}
                       phx-keyup="update_conn_field" phx-value-field="host" phx-debounce="300" />
              </div>
            </div>
          </div>
          <div class="column">
            <div class="field">
              <label class="label">Port</label>
              <div class="control">
                <input class="input" type="text" placeholder="3306"
                       value={@conn_port}
                       phx-keyup="update_conn_field" phx-value-field="port" phx-debounce="300" />
              </div>
            </div>
          </div>
        </div>

        <div class="columns">
          <div class="column">
            <div class="field">
              <label class="label">Username</label>
              <div class="control">
                <input class="input" type="text" placeholder="root"
                       value={@conn_user}
                       phx-keyup="update_conn_field" phx-value-field="user" phx-debounce="300" />
              </div>
            </div>
          </div>
          <div class="column">
            <div class="field">
              <label class="label">Password</label>
              <div class="control">
                <input class="input" type="password" placeholder="••••••••"
                       value={@conn_password}
                       phx-keyup="update_conn_field" phx-value-field="password" phx-debounce="300" />
              </div>
            </div>
          </div>
        </div>

        <div class="columns">
          <div class="column">
            <div class="field">
              <label class="label">Database</label>
              <div class="control">
                <input class="input" type="text" placeholder="teslalogger"
                       value={@conn_database}
                       phx-keyup="update_conn_field" phx-value-field="database" phx-debounce="300" />
              </div>
            </div>
          </div>
          <div class="column">
            <div class="field">
              <label class="label">Timezone</label>
              <div class="control">
                <input class="input" type="text" placeholder="Europe/Berlin"
                       value={@conn_timezone}
                       phx-keyup="update_conn_field" phx-value-field="timezone" phx-debounce="300" />
              </div>
              <p class="help">IANA timezone of your TeslaLogger data (e.g. Europe/Berlin)</p>
            </div>
          </div>
        </div>

        <%= if match?({:error, _}, @status.state) and not preflight_passed?(@status.preflight_steps) do %>
          <div class="notification is-danger is-light mb-3 py-2 px-3">
            <strong>Connection failed:</strong> <%= elem(@status.state, 1) %>
          </div>
        <% end %>

        <div class="field mt-4">
          <div class="control">
            <button class="button is-info is-fullwidth" phx-click="test_connection"
                    phx-disable-with="Testing...">
              <span class="icon"><span class="mdi mdi-connection"></span></span>
              <span>Test Connection</span>
            </button>
          </div>
        </div>
      </div>
    <% end %>

    <%!-- Preflight Check Box (shown while running or after completing) --%>
    <%= if @status.preflight_steps != [] and @status.state != :unconfigured do %>
      <div class="box mb-4">
        <div class="is-flex is-justify-content-space-between is-align-items-center mb-3">
          <h3 class="title is-5 mb-0">Preflight Check</h3>
          <%= if preflight_all_complete?(@status.preflight_steps) do %>
            <span class="icon has-text-success"><span class="mdi mdi-check-circle mdi-24px"></span></span>
          <% end %>
        </div>

        <%= for step <- @status.preflight_steps do %>
          <div class="is-flex is-align-items-center mb-2">
            <span class="icon mr-2">
              <%= case step.status do %>
                <% :pending -> %>
                  <span class="mdi mdi-circle-outline has-text-grey-light"></span>
                <% :running -> %>
                  <span class="mdi mdi-loading mdi-spin has-text-info"></span>
                <% :complete -> %>
                  <span class="mdi mdi-check-circle has-text-success"></span>
                <% {:error, _} -> %>
                  <span class="mdi mdi-alert-circle has-text-danger"></span>
              <% end %>
            </span>
            <span>
              <strong><%= preflight_step_label(step.name) %></strong>
              <%= if step.detail do %>
                <span class="has-text-grey ml-1">— <%= step.detail %></span>
              <% end %>
            </span>
          </div>
        <% end %>

        <%= if @status.state == :idle do %>
          <div class="mt-3">
            <button class="button is-small is-light" phx-click="reset_connection">
              <span class="icon"><span class="mdi mdi-pencil"></span></span>
              <span>Change Connection</span>
            </button>
          </div>
        <% end %>
      </div>
    <% end %>

    <%!-- Found Cars Box (only after preflight completes) --%>
    <%= if @status.state == :idle and @status.mysql_car_info != [] do %>
      <div class="box mb-4">
        <h3 class="title is-5">Found Cars</h3>

        <%= for car_info <- @status.mysql_car_info do %>
          <div class={"notification is-light py-3 px-4 mb-3 #{car_notification_class(car_info)}"}>
            <div class="is-flex is-justify-content-space-between is-align-items-start">
              <div>
                <p class="mb-1">
                  <strong>Car <%= car_info["id"] %></strong>
                  <%= if car_info["display_name"] do %>
                    — "<%= car_info["display_name"] %>"
                  <% end %>
                </p>

                <p class="mb-1">
                  <%= if car_info["vin"] && car_info["vin"] != "" do %>
                    <span class="icon-text">
                      <span class="icon has-text-success"><span class="mdi mdi-check"></span></span>
                      <span>VIN: <code><%= car_info["vin"] %></code></span>
                    </span>
                  <% else %>
                    <span class="icon-text">
                      <span class="icon has-text-warning"><span class="mdi mdi-alert"></span></span>
                      <span>VIN: <em>Not found — enter manually below</em></span>
                    </span>
                  <% end %>
                </p>

                <p class="mb-1">
                  <span class="icon-text">
                    <span class="icon has-text-grey"><span class="mdi mdi-chart-line"></span></span>
                    <span class="has-text-grey">
                      TeslaLogger: <%= car_info["drive_count"] || 0 %> drives,
                      <%= car_info["charge_count"] || 0 %> charges,
                      <%= car_info["pos_count"] || 0 %> positions
                      <%= if car_info["data_from"] do %>
                        (<%= format_date(car_info["data_from"]) %> – <%= format_date(car_info["data_to"]) %>)
                      <% end %>
                    </span>
                  </span>
                </p>

                <p class="mb-0">
                  <%= if car_info["tm_data_counts"] && map_size(car_info["tm_data_counts"]) > 0 do %>
                    <span class="icon-text">
                      <span class="icon has-text-info"><span class="mdi mdi-database"></span></span>
                      <span>TeslaMate: <%= format_tm_data_counts(car_info["tm_data_counts"]) %></span>
                    </span>
                  <% else %>
                    <span class="icon-text">
                      <span class="icon has-text-grey-light"><span class="mdi mdi-database-outline"></span></span>
                      <span class="has-text-grey">TeslaMate: No existing data</span>
                    </span>
                  <% end %>
                </p>
              </div>

              <%= if car_info["vin"] && car_info["vin"] != "" do %>
                <button class="button is-small is-info"
                        phx-click="apply_car_values" phx-value-car-id={car_info["id"]}>
                  <span class="icon"><span class="mdi mdi-content-copy"></span></span>
                  <span>Apply Values</span>
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Car Configuration Box --%>
      <div class="box mb-4">
        <h3 class="title is-5"><%= gettext("Car Configuration") %></h3>

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

      <%!-- Import Mode Box --%>
      <div class="box">
        <h3 class="title is-5"><%= gettext("Import Mode") %></h3>

        <div class="field">
          <label class={"radio mb-3 #{if @status.tm_has_data, do: "has-text-grey-light"}"} style="display: block;">
            <input type="radio" name="import_mode" value="clean"
                   checked={@import_mode == "clean"}
                   disabled={@status.tm_has_data}
                   phx-click="select_mode" phx-value-value="clean" />
            <strong>Clean database</strong>
            <p class={"ml-5 #{if @status.tm_has_data, do: "has-text-grey-light", else: "has-text-grey"}"}>
              Expects an empty TeslaMate database for this vehicle.
              Aborts if data already exists.
            </p>
            <%= if @status.tm_has_data do %>
              <p class="ml-5 is-size-7 has-text-warning-dark">
                <span class="icon is-small"><span class="mdi mdi-information-outline"></span></span>
                TeslaMate already has data for this vehicle. Delete it manually if you want a clean import.
              </p>
            <% end %>
          </label>

          <label class={"radio mb-3 #{unless @status.tm_has_data, do: "has-text-grey-light"}"} style="display: block;">
            <input type="radio" name="import_mode" value="merge_tm"
                   checked={@import_mode == "merge_tm"}
                   disabled={not @status.tm_has_data}
                   phx-click="select_mode" phx-value-value="merge_tm" />
            <strong>Merge (TeslaMate priority)</strong>
            <p class={"ml-5 #{if @status.tm_has_data, do: "has-text-grey", else: "has-text-grey-light"}"}>
              Only imports data for time periods where TeslaMate has no data.
              Existing TeslaMate data remains unchanged.
            </p>
            <%= unless @status.tm_has_data do %>
              <p class="ml-5 is-size-7 has-text-grey-light">
                <span class="icon is-small"><span class="mdi mdi-information-outline"></span></span>
                No existing TeslaMate data — merge not needed
              </p>
            <% end %>
          </label>

          <label class={"radio mb-3 #{unless @status.tm_has_data, do: "has-text-grey-light"}"} style="display: block;">
            <input type="radio" name="import_mode" value="merge_tl"
                   checked={@import_mode == "merge_tl"}
                   disabled={not @status.tm_has_data}
                   phx-click="select_mode" phx-value-value="merge_tl" />
            <strong>Merge (TeslaLogger priority)</strong>
            <%= if @status.tm_has_data do %>
              <p class="has-text-danger ml-5">
                <span class="icon"><span class="mdi mdi-alert"></span></span>
                Deletes overlapping TeslaMate data and replaces it with TeslaLogger data!
              </p>
            <% else %>
              <p class="ml-5 is-size-7 has-text-grey-light">
                <span class="icon is-small"><span class="mdi mdi-information-outline"></span></span>
                No existing TeslaMate data — merge not needed
              </p>
            <% end %>
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

    <%!-- Destructive Mode Confirmation Modal --%>
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

    <%!-- Import Progress --%>
    <%= if @status.state == :running or @status.state == :complete or
           (match?({:error, _}, @status.state) and @status.current_step != nil) do %>
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
                        <span class="mdi mdi-loading mdi-spin has-text-info"></span>
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
                  <%= cond do %>
                    <% step.status == :complete and step.total > 0 -> %>
                      <strong><%= format_number(step.imported) %></strong>
                    <% step.status == :complete -> %>
                      <span class="icon has-text-success is-small">
                        <span class="mdi mdi-check"></span>
                      </span>
                    <% true -> %>
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
        <p class="mb-2"><strong>Import complete!</strong></p>
        <%= if @status.geocoding_lookups > 0 do %>
          <p class="mb-2">
            <span class="icon"><span class="mdi mdi-map-marker-multiple"></span></span>
            <strong><%= format_number(@status.geocoding_lookups) %></strong> addresses need reverse geocoding via Nominatim
            (rate limit: 1 request per ~2 seconds).
            <br/>
            Estimated time: <strong><%= format_geocoding_duration(@status.geocoding_lookups) %></strong>.
            This runs automatically in the background.
          </p>
          <p class="is-size-7 has-text-success-dark">
            Until geocoding is complete, some Grafana dashboards may show coordinates instead of
            addresses, and geofence filters may not match all entries.
          </p>
        <% else %>
          <p>All addresses already resolved. Check the Grafana dashboards to verify the imported data.</p>
        <% end %>
      </div>
    <% end %>

    <%= if match?({:error, _}, @status.state) and @status.current_step != nil do %>
      <div class="notification is-danger">
        <strong>Import failed:</strong>
        <code><%= inspect(elem(@status.state, 1), pretty: true) %></code>
      </div>
    <% end %>

    <%= if @status.warnings != [] do %>
      <div class="box mt-4">
        <h3 class="title is-5"><%= gettext("Validation Warnings") %></h3>
        <div class="content" style="max-height: 400px; overflow-y: auto;">
          <%= for {category, warnings} <- group_warnings(@status.warnings) do %>
            <div class="mb-4">
              <p class="mb-1">
                <span><%= warning_icon(category) %></span>
                <strong><%= warning_title(category) %></strong>
                <span class="tag is-light is-rounded ml-1"><%= length(warnings) %></span>
              </p>
              <p class="is-size-7 has-text-grey mb-2 ml-5"><%= warning_explanation(category) %></p>
              <details class="ml-5">
                <summary class="is-size-7 has-text-grey-light" style="cursor: pointer;">
                  Show details (<%= length(warnings) %> entries)
                </summary>
                <ul class="is-size-7 mt-1">
                  <%= for warning <- Enum.take(warnings, 20) do %>
                    <li class="has-text-grey"><%= warning %></li>
                  <% end %>
                  <%= if length(warnings) > 20 do %>
                    <li class="has-text-grey-light">... and <%= length(warnings) - 20 %> more</li>
                  <% end %>
                </ul>
              </details>
            </div>
          <% end %>
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

  defp preflight_all_complete?(steps) do
    Enum.all?(steps, fn s -> s.status == :complete end)
  end

  defp preflight_passed?(steps) do
    steps != [] and preflight_all_complete?(steps)
  end

  defp preflight_step_label(:connecting), do: "Connecting to MySQL"
  defp preflight_step_label(:validating_timezone), do: "Validating timezone"
  defp preflight_step_label(:checking_schema), do: "Checking database schema"
  defp preflight_step_label(:reading_source), do: "Reading TeslaLogger data"
  defp preflight_step_label(:checking_target), do: "Checking TeslaMate database"
  defp preflight_step_label(name), do: Atom.to_string(name)

  defp car_notification_class(car_info) do
    cond do
      car_info["vin"] == nil or car_info["vin"] == "" -> "is-warning"
      car_info["tm_data_counts"] && map_size(car_info["tm_data_counts"]) > 0 -> "is-info"
      true -> "is-success"
    end
  end

  defp format_date(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt) |> Date.to_string()
  defp format_date(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_string()
  defp format_date(%Date{} = d), do: Date.to_string(d)
  defp format_date(_), do: "?"

  defp format_tm_data_counts(counts) when map_size(counts) == 0, do: "No existing data"

  defp format_tm_data_counts(counts) do
    counts
    |> Enum.map(fn {k, v} -> "#{format_number(v)} #{k}" end)
    |> Enum.join(", ")
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

  # Estimate: ~2 seconds per lookup (1.5s sleep + network)
  defp format_geocoding_duration(lookups) when lookups <= 0, do: "—"

  defp format_geocoding_duration(lookups) do
    total_seconds = lookups * 2
    total_minutes = ceil(total_seconds / 60)

    cond do
      total_minutes < 60 ->
        if total_minutes == 1, do: "~1 minute", else: "~#{total_minutes} minutes"

      true ->
        hours = total_seconds / 3600
        # Round up to nearest 0.5 hours
        rounded_hours = Float.ceil(hours * 2) / 2

        cond do
          rounded_hours == 1.0 ->
            "~1 hour"

          rounded_hours == Float.floor(rounded_hours) ->
            "~#{round(rounded_hours)} hours"

          true ->
            "~#{:erlang.float_to_binary(rounded_hours, decimals: 1)} hours"
        end
    end
  end

  # Warning grouping and display helpers

  defp group_warnings(warnings) do
    warnings
    |> Enum.group_by(&warning_category/1)
    |> Enum.sort_by(fn {cat, _} -> warning_sort_order(cat) end)
  end

  defp warning_category(warning) do
    cond do
      String.contains?(warning, "positions without drive") -> :orphan_positions
      String.contains?(warning, "[drives#overlap]") -> :drive_overlaps
      String.contains?(warning, "[charging_processes#overlap]") -> :charge_overlaps
      true -> :other
    end
  end

  defp warning_sort_order(:orphan_positions), do: 1
  defp warning_sort_order(:drive_overlaps), do: 2
  defp warning_sort_order(:charge_overlaps), do: 3
  defp warning_sort_order(:other), do: 4

  defp warning_icon(:orphan_positions), do: "ℹ️"
  defp warning_icon(:drive_overlaps), do: "⚠️"
  defp warning_icon(:charge_overlaps), do: "⚠️"
  defp warning_icon(:other), do: "❓"

  defp warning_title(:orphan_positions), do: "Positions without drive assignment"
  defp warning_title(:drive_overlaps), do: "Drive time overlaps"
  defp warning_title(:charge_overlaps), do: "Charging session overlaps"
  defp warning_title(:other), do: "Other warnings"

  defp warning_explanation(:orphan_positions) do
    "Harmless. TeslaLogger records positions outside of drives (e.g. while parked). " <>
      "These are imported but not assigned to any drive. Grafana dashboards are not affected."
  end

  defp warning_explanation(:drive_overlaps) do
    "Cosmetic. Usually caused by very short drives (car briefly woke up) that create " <>
      "1-second time overlaps. No data loss, dashboards work normally."
  end

  defp warning_explanation(:charge_overlaps) do
    "Cosmetic. Usually caused by brief charging sessions at time boundaries. " <>
      "No data loss, dashboards work normally."
  end

  defp warning_explanation(:other), do: "Review these entries manually if unexpected."
end
