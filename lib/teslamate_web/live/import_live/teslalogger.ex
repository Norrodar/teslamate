defmodule TeslaMateWeb.ImportLive.TeslaLogger do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Import.TeslaLogger, as: TLImport
  alias TeslaMate.Import.TeslaLogger.Status

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  # Wizard steps: 1 Connection · 2 Checks · 3 Vehicles · 4 Mode+Preview · 5 Import
  @last_step 5

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
        |> assign(wizard_step: initial_wizard_step(status))
        |> assign(car_vin: "")
        |> assign(car_eid: "")
        |> assign(car_vid: "")
        |> assign(import_mode: "clean")
        |> assign(selected_car_ids: default_selected_car_ids(status))
        |> assign(manual_entry: false)
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

    case TLImport.preflight() do
      :ok -> {:noreply, assign(socket, wizard_step: 2)}
      {:error, :busy} -> {:noreply, socket}
    end
  end

  def handle_event("reset_connection", _params, socket) do
    :ok = TLImport.reset()
    {:noreply, assign(socket, wizard_step: 1)}
  end

  def handle_event("wizard_next", _params, socket) do
    next = min(socket.assigns.wizard_step + 1, max_reachable_step(socket.assigns.status))
    {:noreply, socket |> assign(wizard_step: next) |> maybe_load_preview(next)}
  end

  def handle_event("wizard_back", _params, socket) do
    # Step 2 (preflight) is transient — going back from car mapping returns to the form.
    back =
      case socket.assigns.wizard_step do
        3 -> 1
        step -> max(step - 1, 1)
      end

    {:noreply, assign(socket, wizard_step: back)}
  end

  def handle_event("wizard_goto", %{"step" => step_str}, socket) do
    step = String.to_integer(step_str)

    if step < socket.assigns.wizard_step and step <= max_reachable_step(socket.assigns.status) do
      {:noreply, assign(socket, wizard_step: step)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh_preview", _params, socket) do
    _result = TLImport.preview()
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
      mode == "clean" and socket.assigns.status.tm_has_data ->
        {:noreply, socket}

      mode in ["merge_tm", "merge_tl"] and not socket.assigns.status.tm_has_data ->
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, import_mode: mode)}
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

  def handle_event("toggle_car", %{"car-id" => id_str}, socket) do
    id = String.to_integer(id_str)
    selected = socket.assigns.selected_car_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected_car_ids: selected)}
  end

  def handle_event("toggle_manual_entry", _params, socket) do
    {:noreply, assign(socket, manual_entry: not socket.assigns.manual_entry)}
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

    wizard_step =
      cond do
        # Preflight failed → back to the connection form (error shown there)
        socket.assigns.wizard_step == 2 and match?({:error, _}, status.state) ->
          1

        # Import started or finished (possibly from another tab) → progress view
        status.state in [:running, :complete] ->
          @last_step

        true ->
          socket.assigns.wizard_step
      end

    # Seed the default car selection once, when preflight first delivers the car list.
    selected_car_ids =
      if socket.assigns.status.mysql_car_info == [] and status.mysql_car_info != [] do
        default_selected_car_ids(status)
      else
        socket.assigns.selected_car_ids
      end

    socket =
      assign(socket,
        status: status,
        import_mode: import_mode,
        wizard_step: wizard_step,
        selected_car_ids: selected_car_ids
      )

    {:noreply, socket}
  end

  defp do_start_import(socket) do
    car_ids = MapSet.to_list(socket.assigns.selected_car_ids)
    car_mapping = manual_car_mapping(socket)

    mode =
      case socket.assigns.import_mode do
        "clean" -> :clean
        "merge_tm" -> :merge_tm_priority
        "merge_tl" -> :merge_tl_priority
        _ -> :clean
      end

    case TLImport.run(car_mapping, mode: mode, car_ids: car_ids) do
      :ok ->
        %Status{} = current_status = socket.assigns.status

        {:noreply,
         assign(socket, status: %{current_status | state: :running}, wizard_step: @last_step)}

      {:error, :already_running} ->
        {:noreply, assign(socket, wizard_step: @last_step)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # VIN/EID/VID override only when manual entry is on; applied to the first
  # selected car that lacks a VIN in TeslaLogger.
  defp manual_car_mapping(%{assigns: %{manual_entry: false}}), do: %{}

  defp manual_car_mapping(socket) do
    %{car_vin: vin, car_eid: eid, car_vid: vid, selected_car_ids: selected} = socket.assigns

    target =
      socket.assigns.status.mysql_car_info
      |> Enum.filter(fn c -> MapSet.member?(selected, c["id"]) end)
      |> Enum.find(fn c -> c["vin"] in [nil, ""] end)

    cond do
      target == nil ->
        %{}

      vin == "" and eid == "" and vid == "" ->
        %{}

      true ->
        %{
          target["id"] => %{
            vin: if(vin != "", do: vin),
            eid: safe_to_integer(eid),
            vid: safe_to_integer(vid)
          }
        }
    end
  end

  ## Wizard navigation

  defp initial_wizard_step(%Status{state: :unconfigured}), do: 1
  defp initial_wizard_step(%Status{state: :preflight}), do: 2
  defp initial_wizard_step(%Status{state: :idle}), do: 3
  defp initial_wizard_step(%Status{state: s}) when s in [:running, :complete], do: @last_step
  defp initial_wizard_step(%Status{state: {:error, _}, current_step: nil}), do: 1
  defp initial_wizard_step(%Status{}), do: @last_step

  defp max_reachable_step(%Status{} = status) do
    cond do
      status.state in [:running, :complete] -> @last_step
      match?({:error, _}, status.state) and status.current_step != nil -> @last_step
      # Idle = preflight passed: reachable up to Mode+Preview (4); Import (5) only after start
      status.state == :idle -> 4
      status.state == :preflight -> 2
      true -> 1
    end
  end

  # Pre-select all cars that have a VIN (the ones that import cleanly).
  defp default_selected_car_ids(%Status{mysql_car_info: cars}) do
    cars
    |> Enum.filter(fn c -> c["vin"] not in [nil, ""] end)
    |> Enum.map(fn c -> c["id"] end)
    |> MapSet.new()
  end

  # Entering the Mode+Preview step triggers preview loading once.
  defp maybe_load_preview(socket, 4) do
    case socket.assigns.status.preview do
      nil -> _result = TLImport.preview()
      {:error, _} -> _result = TLImport.preview()
      _ -> :ok
    end

    socket
  end

  defp maybe_load_preview(socket, _step), do: socket

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
     <.wizard_steps current={@wizard_step} max={max_reachable_step(@status)} />
    <%!-- Step 1: Connection Form --%>
    <%= if @wizard_step == 1 do %>
      <div class="box mb-4">
        <h3 class="title is-5"><%= gettext("Database Connection") %></h3>
        
        <p class="mb-4 has-text-grey">
          <%= gettext("Enter the connection details for your TeslaLogger MySQL database.") %>
        </p>
        
        <div class="columns">
          <div class="column is-two-thirds">
            <div class="field">
              <label class="label"><%= gettext("Host") %></label>
              <div class="control">
                <input
                  class="input"
                  type="text"
                  placeholder="localhost"
                  value={@conn_host}
                  phx-keyup="update_conn_field"
                  phx-value-field="host"
                  phx-debounce="300"
                />
              </div>
            </div>
          </div>
          
          <div class="column">
            <div class="field">
              <label class="label"><%= gettext("Port") %></label>
              <div class="control">
                <input
                  class="input"
                  type="text"
                  placeholder="3306"
                  value={@conn_port}
                  phx-keyup="update_conn_field"
                  phx-value-field="port"
                  phx-debounce="300"
                />
              </div>
            </div>
          </div>
        </div>
        
        <div class="columns">
          <div class="column">
            <div class="field">
              <label class="label"><%= gettext("Username") %></label>
              <div class="control">
                <input
                  class="input"
                  type="text"
                  placeholder="root"
                  value={@conn_user}
                  phx-keyup="update_conn_field"
                  phx-value-field="user"
                  phx-debounce="300"
                />
              </div>
            </div>
          </div>
          
          <div class="column">
            <div class="field">
              <label class="label"><%= gettext("Password") %></label>
              <div class="control">
                <input
                  class="input"
                  type="password"
                  placeholder="••••••••"
                  value={@conn_password}
                  phx-keyup="update_conn_field"
                  phx-value-field="password"
                  phx-debounce="300"
                />
              </div>
            </div>
          </div>
        </div>
        
        <div class="columns">
          <div class="column">
            <div class="field">
              <label class="label"><%= gettext("Database") %></label>
              <div class="control">
                <input
                  class="input"
                  type="text"
                  placeholder="teslalogger"
                  value={@conn_database}
                  phx-keyup="update_conn_field"
                  phx-value-field="database"
                  phx-debounce="300"
                />
              </div>
            </div>
          </div>
          
          <div class="column">
            <div class="field">
              <label class="label"><%= gettext("Timezone") %></label>
              <div class="control">
                <input
                  class="input"
                  type="text"
                  placeholder="Europe/Berlin"
                  value={@conn_timezone}
                  phx-keyup="update_conn_field"
                  phx-value-field="timezone"
                  phx-debounce="300"
                />
              </div>
              
              <p class="help">
                <%= gettext("IANA timezone of your TeslaLogger data (e.g. Europe/Berlin)") %>
              </p>
            </div>
          </div>
        </div>
        
        <%= if match?({:error, _}, @status.state) and not preflight_passed?(@status.preflight_steps) do %>
          <div class="notification is-danger is-light mb-3 py-2 px-3">
            <strong><%= gettext("Connection failed:") %></strong> <%= elem(@status.state, 1) %>
          </div>
        <% end %>
        
        <div class="field mt-4">
          <div class="control">
            <button
              class="button is-info is-fullwidth"
              phx-click="test_connection"
              phx-disable-with={gettext("Testing…")}
            >
              <span class="icon"><span class="mdi mdi-connection"></span></span>
              <span><%= gettext("Test connection") %></span>
            </button>
          </div>
        </div>
      </div>
    <% end %>
     <%!-- Step 2: Preflight Check --%>
    <%= if @wizard_step == 2 do %>
      <div class="box mb-4">
        <div class="is-flex is-justify-content-space-between is-align-items-center mb-3">
          <h3 class="title is-5 mb-0"><%= gettext("Preflight Check") %></h3>
          
          <%= if preflight_passed?(@status.preflight_steps) do %>
            <span class="icon has-text-success">
              <span class="mdi mdi-check-circle mdi-24px"></span>
            </span>
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
        
        <div class="is-flex is-justify-content-space-between mt-4">
          <button class="button is-light" phx-click="reset_connection">
            <span class="icon"><span class="mdi mdi-pencil"></span></span>
            <span><%= gettext("Change connection") %></span>
          </button>
          
          <button
            class="button is-success"
            phx-click="wizard_next"
            disabled={not preflight_passed?(@status.preflight_steps)}
          >
            <span><%= gettext("Continue") %></span>
            <span class="icon"><span class="mdi mdi-arrow-right"></span></span>
          </button>
        </div>
      </div>
    <% end %>
     <%!-- Step 3: Vehicle selection --%>
    <%= if @wizard_step == 3 do %>
      <.step_vehicles
        cars={@status.mysql_car_info}
        selected_car_ids={@selected_car_ids}
        manual_entry={@manual_entry}
        car_vin={@car_vin}
        car_eid={@car_eid}
        car_vid={@car_vid}
      />
    <% end %>
     <%!-- Step 4: Import mode + live preview --%>
    <%= if @wizard_step == 4 do %>
      <.step_mode_preview
        status={@status}
        import_mode={@import_mode}
        car_vin={@car_vin}
        selected_car_ids={@selected_car_ids}
      />
    <% end %>
     <%!-- Destructive Mode Confirmation Modal --%>
    <%= if @show_destructive_warning do %>
      <div class="modal is-active">
        <div class="modal-background" phx-click="cancel_destructive"></div>
        
        <div class="modal-card">
          <header class="modal-card-head has-background-danger">
            <p class="modal-card-title has-text-white">
              <span class="icon"><span class="mdi mdi-alert"></span></span> <%= gettext(
                "Warning: Destructive Import"
              ) %>
            </p>
          </header>
          
          <section class="modal-card-body">
            <p class="mb-3">
              <%= raw(
                gettext(
                  "<strong>This mode deletes existing TeslaMate data</strong> in time periods that overlap with TeslaLogger data."
                )
              ) %>
            </p>
            
            <p class="has-text-danger">
              <%= gettext("This cannot be undone! Make sure you have a backup.") %>
            </p>
          </section>
          
          <footer class="modal-card-foot">
            <button class="button" phx-click="cancel_destructive"><%= gettext("Cancel") %></button>
            <button class="button is-danger" phx-click="confirm_destructive">
              <%= gettext("Yes, start import") %>
            </button>
          </footer>
        </div>
      </div>
    <% end %>
     <%!-- Step 5: Import Progress --%>
    <%= if @wizard_step == 5 do %>
      <div class="box">
        <h3 class="title is-5"><%= gettext("Import Progress") %></h3>
         <.progress_bar status={@status} />
        <%= if @status.car_count > 0 do %>
          <p class="mb-2">
            <%= gettext("Importing %{count} car(s) from TeslaLogger", count: @status.car_count) %>
          </p>
        <% end %>
        
        <%= if @status.import_mode != :clean do %>
          <p class="mb-4">
            <span class="tag is-info is-light"><%= mode_label(@status.import_mode) %></span>
          </p>
        <% end %>
        
        <table class="table is-fullwidth is-hoverable" style="table-layout: fixed;">
          <colgroup>
            <col style="width: 22%;" /> <col style="width: 10%;" /> <col style="width: 28%;" />
            <col style="width: 22%;" /> <col style="width: 18%;" />
          </colgroup>
          
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
      <div class="notification is-success is-light">
        <p class="mb-2"><strong><%= gettext("Import complete!") %></strong></p>
        
        <%= if @status.geocoding_lookups > 0 do %>
          <p class="mb-2">
            <span class="icon"><span class="mdi mdi-map-marker-multiple"></span></span> <%= raw(
              gettext(
                "<strong>%{count}</strong> addresses need reverse geocoding via Nominatim (rate limit: ~1 request per 2 seconds).",
                count: format_number(@status.geocoding_lookups)
              )
            ) %> <br /> <%= gettext("Estimated time:") %>
            <strong><%= format_duration(@status.geocoding_lookups * 2) %></strong>
            (<%= gettext("done around") %> <strong>
              <span
                id="geocoding-eta"
                phx-hook="LocalTime"
                data-date={geocoding_finish_iso(@status.geocoding_lookups)}
              >
              </span>
            </strong>). <%= gettext(
              "This runs automatically in the background."
            ) %>
          </p>
          
          <p class="is-size-7">
            <%= gettext(
              "Until geocoding is complete, some Grafana dashboards may show coordinates instead of addresses, and geofence filters may not match all entries."
            ) %>
          </p>
        <% else %>
          <p>
            <%= gettext(
              "All addresses already resolved. Check the Grafana dashboards to verify the imported data."
            ) %>
          </p>
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
                <span class="icon"><span class={"mdi #{warning_icon(category)}"}></span></span>
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

  ## Components

  defp wizard_steps(assigns) do
    assigns = assign(assigns, :labels, wizard_step_labels())

    ~H"""
    <div class="is-flex is-align-items-flex-start mb-5">
      <%= for {label, n} <- Enum.with_index(@labels, 1) do %>
        <%= if n > 1 do %>
          <div class="is-flex-grow-1 mt-4" style="height: 2px;">
            <div
              class={"#{if n <= @current, do: "has-background-success", else: "has-background-grey-lighter"}"}
              style="height: 100%;"
            >
            </div>
          </div>
        <% end %>
        
        <div class="has-text-centered" style="min-width: 4.5rem;">
          <span
            class={wizard_circle_class(n, @current)}
            style="display: inline-flex; align-items: center; justify-content: center; width: 2rem; height: 2rem; border-radius: 50%;"
            phx-click={if n < @current and n <= @max, do: "wizard_goto"}
            phx-value-step={n}
          >
            <%= if n < @current do %>
              <span class="mdi mdi-check"></span>
            <% else %>
              <%= n %>
            <% end %>
          </span>
          
          <p class={"is-size-7 mt-1 #{if n == @current, do: "has-text-weight-bold"}"}><%= label %></p>
        </div>
      <% end %>
    </div>
    """
  end

  defp wizard_step_labels do
    [
      gettext("Connection"),
      gettext("Checks"),
      gettext("Vehicles"),
      gettext("Preview"),
      gettext("Import")
    ]
  end

  defp wizard_circle_class(n, current) do
    cond do
      n < current -> "has-background-success has-text-white"
      n == current -> "has-background-info has-text-white"
      true -> "has-background-grey-lighter has-text-grey"
    end
  end

  ## Step 3: vehicle selection

  defp step_vehicles(assigns) do
    ~H"""
    <div class="box mb-4">
      <h3 class="title is-5"><%= gettext("Select vehicles to import") %></h3>
      
      <%= if @cars == [] do %>
        <p class="has-text-grey"><%= gettext("No vehicles found in TeslaLogger.") %></p>
      <% else %>
        <%= for car <- @cars do %>
          <label
            class={"notification is-light py-3 px-4 mb-3 is-block #{car_notification_class(car)}"}
            style="cursor: pointer;"
          >
            <div class="is-flex is-align-items-flex-start">
              <input
                type="checkbox"
                class="mt-1 mr-3"
                checked={MapSet.member?(@selected_car_ids, car["id"])}
                phx-click="toggle_car"
                phx-value-car-id={car["id"]}
              />
              <div>
                <p class="mb-1">
                  <strong><%= gettext("Car %{id}", id: car["id"]) %></strong> <%= if car[
                                                                                       "display_name"
                                                                                     ],
                                                                                     do:
                                                                                       "— „#{car["display_name"]}”" %>
                </p>
                
                <p class="mb-1">
                  <%= if car["vin"] && car["vin"] != "" do %>
                    <span class="icon-text">
                      <span class="icon has-text-success"><span class="mdi mdi-check"></span></span>
                      <span>VIN: <code><%= car["vin"] %></code></span>
                    </span>
                  <% else %>
                    <span class="icon-text">
                      <span class="icon has-text-warning"><span class="mdi mdi-alert"></span></span>
                      <span><%= gettext("VIN: not found — use manual entry below") %></span>
                    </span>
                  <% end %>
                </p>
                
                <p class="mb-1 is-size-7 has-text-grey">
                  <span class="icon"><span class="mdi mdi-chart-line"></span></span> <%= gettext(
                    "TeslaLogger: %{drives} drives, %{charges} charges, %{positions} positions",
                    drives: car["drive_count"] || 0,
                    charges: car["charge_count"] || 0,
                    positions: car["pos_count"] || 0
                  ) %>
                  <%= if car["data_from"] do %>
                    (<%= format_date(car["data_from"]) %> – <%= format_date(car["data_to"]) %>)
                  <% end %>
                </p>
                
                <p class="mb-0 is-size-7">
                  <%= if car["tm_data_counts"] && map_size(car["tm_data_counts"]) > 0 do %>
                    <span class="icon-text has-text-info">
                      <span class="icon"><span class="mdi mdi-database"></span></span>
                      <span>
                        <%= gettext("TeslaMate: %{counts}",
                          counts: format_tm_data_counts(car["tm_data_counts"])
                        ) %>
                      </span>
                    </span>
                  <% else %>
                    <span class="has-text-grey"><%= gettext("TeslaMate: no existing data") %></span>
                  <% end %>
                </p>
              </div>
            </div>
          </label>
        <% end %>
      <% end %>
       <%!-- Manual entry toggle --%>
      <label class="checkbox mt-2" style="cursor: pointer;">
        <input type="checkbox" checked={@manual_entry} phx-click="toggle_manual_entry" /> <%= gettext(
          "Manual entry (VIN / EID / VID for a car without a VIN)"
        ) %>
      </label>
      
      <%= if @manual_entry do %>
        <div class="box mt-3 mb-0">
          <div class="field">
            <label class="label"><%= gettext("VIN") %></label>
            <div class="control">
              <input
                class="input"
                type="text"
                placeholder="5YJ3E1EA1LF000000"
                value={@car_vin}
                phx-keyup="update_car_vin"
                phx-debounce="300"
              />
            </div>
          </div>
          
          <div class="columns">
            <div class="column">
              <div class="field">
                <label class="label">
                  EID
                  <span class="has-text-grey-light has-text-weight-normal">
                    — <%= gettext("optional") %>
                  </span>
                </label>
                
                <div class="control">
                  <input
                    class="input"
                    type="text"
                    placeholder="1234567890"
                    value={@car_eid}
                    phx-keyup="update_car_eid"
                    phx-debounce="300"
                  />
                </div>
              </div>
            </div>
            
            <div class="column">
              <div class="field">
                <label class="label">
                  VID
                  <span class="has-text-grey-light has-text-weight-normal">
                    — <%= gettext("optional") %>
                  </span>
                </label>
                
                <div class="control">
                  <input
                    class="input"
                    type="text"
                    placeholder="1234567891"
                    value={@car_vid}
                    phx-keyup="update_car_vid"
                    phx-debounce="300"
                  />
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
      
      <div class="is-flex is-justify-content-space-between mt-4">
        <button class="button is-light" phx-click="wizard_back">
          <span class="icon"><span class="mdi mdi-arrow-left"></span></span>
          <span><%= gettext("Back") %></span>
        </button>
        
        <button
          class="button is-success"
          phx-click="wizard_next"
          disabled={vehicles_continue_blocked?(@selected_car_ids, @manual_entry)}
        >
          <span><%= gettext("Continue to preview") %></span>
          <span class="icon"><span class="mdi mdi-arrow-right"></span></span>
        </button>
      </div>
    </div>
    """
  end

  defp vehicles_continue_blocked?(selected_car_ids, manual_entry) do
    MapSet.size(selected_car_ids) == 0 and not manual_entry
  end

  ## Step 5: weighted progress bar

  defp progress_bar(assigns) do
    pct = round(Status.progress_fraction(assigns.status) * 100)

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:phase, current_phase_label(assigns.status))
      |> assign(:eta, eta_label(assigns.status))

    ~H"""
    <div class="mb-4">
      <div class="is-flex is-justify-content-space-between mb-1">
        <span class="is-size-7 has-text-grey"><%= @phase %></span>
        <span class="is-size-7">
          <%= if @eta do %>
            <span class="has-text-grey mr-2"><%= @eta %></span>
          <% end %>
           <span class="has-text-weight-bold"><%= @pct %>%</span>
        </span>
      </div>
      
      <progress class={"progress #{progress_color(@status.state)}"} value={@pct} max="100">
        <%= @pct %>%
      </progress>
    </div>
    """
  end

  # Estimated time remaining from the measured rate so far. Nil until there is
  # enough progress for a meaningful estimate.
  defp eta_label(%Status{state: :running, started_at: %DateTime{} = started} = status) do
    p = Status.progress_fraction(status)

    if p > 0.02 and p < 1.0 do
      elapsed = DateTime.diff(DateTime.utc_now(), started)
      remaining = round(elapsed * (1 - p) / p)
      gettext("approx. %{duration} left", duration: format_duration(remaining))
    end
  end

  defp eta_label(_status), do: nil

  defp format_duration(seconds) when seconds < 60, do: gettext("< 1 min")

  defp format_duration(seconds) when seconds < 3600 do
    gettext("%{count} min", count: max(round(seconds / 60), 1))
  end

  defp format_duration(seconds) do
    hours = Float.round(seconds / 3600, 1)
    gettext("%{count} h", count: hours)
  end

  defp progress_color(:complete), do: "is-success"
  defp progress_color({:error, _}), do: "is-danger"
  defp progress_color(_), do: "is-info"

  defp current_phase_label(%Status{state: :complete}), do: gettext("Done")

  defp current_phase_label(%Status{state: {:error, _}}), do: gettext("Failed")

  defp current_phase_label(%Status{current_step: nil}), do: gettext("Starting…")

  defp current_phase_label(%Status{current_step: name, steps: steps}) do
    step = Enum.find(steps, &(&1.name == name))

    base = step_label(name)

    cond do
      step == nil ->
        base

      step.total > 0 ->
        "#{base} — #{phase_label(step.phase)} (#{format_number(step.imported)}/#{format_number(step.total)})"

      true ->
        "#{base} — #{phase_label(step.phase)}"
    end
  end

  defp step_mode_preview(assigns) do
    ~H"""
    <%!-- Import mode --%>
    <div class="box mb-4">
      <h3 class="title is-5"><%= gettext("Import Mode") %></h3>
      
      <div class="field">
        <label
          class={"radio mb-3 #{if @status.tm_has_data, do: "has-text-grey-light"}"}
          style="display: block;"
        >
          <input
            type="radio"
            name="import_mode"
            value="clean"
            checked={@import_mode == "clean"}
            disabled={@status.tm_has_data}
            phx-click="select_mode"
            phx-value-value="clean"
          /> <strong><%= gettext("Clean database") %></strong>
          <p class={"ml-5 #{if @status.tm_has_data, do: "has-text-grey-light", else: "has-text-grey"}"}>
            <%= gettext(
              "Expects an empty TeslaMate database for this vehicle. Aborts if data already exists."
            ) %>
          </p>
        </label>
        
        <label
          class={"radio mb-3 #{unless @status.tm_has_data, do: "has-text-grey-light"}"}
          style="display: block;"
        >
          <input
            type="radio"
            name="import_mode"
            value="merge_tm"
            checked={@import_mode == "merge_tm"}
            disabled={not @status.tm_has_data}
            phx-click="select_mode"
            phx-value-value="merge_tm"
          /> <strong><%= gettext("Merge (TeslaMate priority)") %></strong>
          <p class={"ml-5 #{if @status.tm_has_data, do: "has-text-grey", else: "has-text-grey-light"}"}>
            <%= gettext(
              "Only imports data for periods where TeslaMate has no data. Existing TeslaMate data is kept."
            ) %>
          </p>
        </label>
        
        <label
          class={"radio mb-3 #{unless @status.tm_has_data, do: "has-text-grey-light"}"}
          style="display: block;"
        >
          <input
            type="radio"
            name="import_mode"
            value="merge_tl"
            checked={@import_mode == "merge_tl"}
            disabled={not @status.tm_has_data}
            phx-click="select_mode"
            phx-value-value="merge_tl"
          /> <strong><%= gettext("Merge (TeslaLogger priority)") %></strong>
          <%= if @status.tm_has_data do %>
            <p class="has-text-danger ml-5">
              <span class="icon"><span class="mdi mdi-alert"></span></span> <%= gettext(
                "Deletes overlapping TeslaMate data and replaces it with TeslaLogger data!"
              ) %>
            </p>
          <% else %>
            <p class="ml-5 is-size-7 has-text-grey-light">
              <%= gettext("No existing TeslaMate data — merge not needed.") %>
            </p>
          <% end %>
        </label>
      </div>
    </div>
     <%!-- Live preview --%>
    <div class="box mb-4">
      <h3 class="title is-5"><%= gettext("Preview — this is what your data would look like") %></h3>
       <%= legend(assigns) %>
      <%= case @status.preview do %>
        <% p when p in [nil, :loading] -> %>
          <p class="has-text-grey">
            <span class="icon"><span class="mdi mdi-loading mdi-spin"></span></span> <%= gettext(
              "Loading sample data from TeslaLogger…"
            ) %>
          </p>
        <% {:error, message} -> %>
          <div class="notification is-danger is-light">
            <strong><%= gettext("Preview failed:") %></strong> <%= message %>
          </div>
          
          <button class="button is-info" phx-click="refresh_preview">
            <span class="icon"><span class="mdi mdi-refresh"></span></span>
            <span><%= gettext("Retry") %></span>
          </button>
        <% {:ok, cars} -> %>
          <%= for car <- cars do %>
            <.preview_car car={car} car_vin={@car_vin} import_mode={@import_mode} />
          <% end %>
      <% end %>
      
      <div class="is-flex is-justify-content-space-between mt-4">
        <button class="button is-light" phx-click="wizard_back">
          <span class="icon"><span class="mdi mdi-arrow-left"></span></span>
          <span><%= gettext("Back") %></span>
        </button>
        
        <button
          class="button is-success"
          phx-click="start_import"
          phx-disable-with={gettext("Starting…")}
          disabled={preview_blocked?(@status.preview, @car_vin, @selected_car_ids)}
        >
          <span class="icon"><span class="mdi mdi-database-import"></span></span>
          <span><%= gettext("Start Import") %></span>
        </button>
      </div>
      
      <%= if preview_blocked?(@status.preview, @car_vin, @selected_car_ids) do %>
        <p class="is-size-7 has-text-danger mt-2">
          <%= gettext("A car has no VIN — go back and enter one manually before continuing.") %>
        </p>
      <% end %>
    </div>
    """
  end

  # Legend explaining the per-row disposition colors, shown only in merge modes.
  defp legend(%{import_mode: "clean"} = assigns), do: ~H""

  defp legend(assigns) do
    ~H"""
    <div class="mb-3 is-size-7">
      <span class="tag is-success is-light mr-2">
        <%= gettext("imported from TeslaLogger") %>
      </span>
      
      <%= if @import_mode == "merge_tm" do %>
        <span class="tag is-info is-light mr-2"><%= gettext("kept from TeslaMate") %></span>
      <% end %>
      
      <%= if @import_mode == "merge_tl" do %>
        <span class="tag is-danger is-light mr-2"><%= gettext("replaces TeslaMate") %></span>
      <% end %>
    </div>
    """
  end

  defp preview_car(assigns) do
    ~H"""
    <div class="mb-5">
      <%!-- Mapping header: TL car → TM car (explicit dark text so it reads in dark mode) --%>
      <div class="notification is-info is-light py-3 px-4 mb-3">
        <span class="icon-text is-flex-wrap-wrap">
          <span>
            <strong><%= gettext("TL Car %{id}", id: @car.tl_car_id) %></strong> <%= if @car.display_name,
              do: "„#{@car.display_name}”" %>
            <%= if vin = preview_vin(@car, @car_vin) do %>
              (VIN <code><%= vin %></code>)
            <% end %>
          </span>
           <span class="icon"><span class="mdi mdi-arrow-right"></span></span>
          <%= cond do %>
            <% @car.tm_car_id != nil -> %>
              <span>
                <%= gettext("TeslaMate car #%{id} (existing, matched by VIN)", id: @car.tm_car_id) %>
              </span>
            <% preview_vin(@car, @car_vin) != nil -> %>
              <span class="has-text-success has-text-weight-medium">
                <%= gettext("New car will be created") %>
              </span>
            <% true -> %>
              <span class="has-text-danger has-text-weight-medium">
                <span class="icon"><span class="mdi mdi-alert"></span></span> <%= gettext(
                  "No VIN — import would abort"
                ) %>
              </span>
          <% end %>
        </span>
      </div>
       <%!-- Drives sample --%>
      <p class="has-text-weight-semibold mb-1"><%= gettext("Last drives") %></p>
      
      <%= if @car.drives == [] do %>
        <p class="is-size-7 has-text-grey mb-3"><%= gettext("No drives found") %></p>
      <% else %>
        <table class="table is-fullwidth is-narrow is-hoverable mb-3">
          <thead>
            <tr>
              <th><%= gettext("Start (local)") %></th>
              
              <th><%= gettext("Start (UTC)") %></th>
              
              <th><%= gettext("Duration") %></th>
              
              <th><%= gettext("Distance") %></th>
              
              <th><%= gettext("Odometer") %></th>
              
              <th>v<sub>max</sub></th>
              
              <th></th>
            </tr>
          </thead>
          
          <tbody>
            <%= for drive <- @car.drives do %>
              <tr>
                <td><%= format_naive(drive.start_date_local) %></td>
                
                <td><%= format_utc(drive.start_date) %></td>
                
                <td><%= format_minutes(drive[:duration_min]) %></td>
                
                <td><%= format_km(drive[:distance]) %></td>
                
                <td><%= format_km(drive[:start_km]) %></td>
                
                <td><%= if drive[:speed_max], do: "#{drive.speed_max} km/h", else: "—" %></td>
                
                <td class="is-flex is-align-items-center" style="gap: 0.35rem;">
                  <%= if has_issue?(@car.issues, {:drive, drive.tl_id}) do %>
                    <span class="icon has-text-warning"><span class="mdi mdi-alert"></span></span>
                  <% end %>
                   <% {label, cls} = disposition(@import_mode, drive[:tm_overlap]) %>
                  <span class={cls}><%= label %></span>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
       <%!-- Charges sample --%>
      <p class="has-text-weight-semibold mb-1"><%= gettext("Last charging sessions") %></p>
      
      <%= if @car.charges == [] do %>
        <p class="is-size-7 has-text-grey mb-3"><%= gettext("No charging sessions found") %></p>
      <% else %>
        <table class="table is-fullwidth is-narrow is-hoverable mb-3">
          <thead>
            <tr>
              <th><%= gettext("Start (local)") %></th>
              
              <th><%= gettext("Start (UTC)") %></th>
              
              <th><%= gettext("Duration") %></th>
              
              <th>SOC</th>
              
              <th><%= gettext("Added") %></th>
              
              <th><%= gettext("Used") %></th>
              
              <th><%= gettext("Cost") %></th>
              
              <th></th>
            </tr>
          </thead>
          
          <tbody>
            <%= for cp <- @car.charges do %>
              <tr>
                <td><%= format_naive(cp.start_date_local) %></td>
                
                <td><%= format_utc(cp.start_date) %></td>
                
                <td><%= format_minutes(cp[:duration_min]) %></td>
                
                <td><%= format_soc(cp[:start_battery_level], cp[:end_battery_level]) %></td>
                
                <td><%= format_kwh(cp[:charge_energy_added]) %></td>
                
                <td><%= format_kwh(cp[:charge_energy_used]) %></td>
                
                <td><%= format_cost(cp[:cost]) %></td>
                
                <td class="is-flex is-align-items-center" style="gap: 0.35rem;">
                  <%= if has_issue?(@car.issues, {:charge, cp.tl_id}) do %>
                    <span class="icon has-text-warning"><span class="mdi mdi-alert"></span></span>
                  <% end %>
                   <% {label, cls} = disposition(@import_mode, cp[:tm_overlap]) %>
                  <span class={cls}><%= label %></span>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
       <%!-- Issues --%>
      <%= if @car.issues == [] do %>
        <div class="notification is-success is-light is-size-7 py-2 px-3">
          <span class="icon"><span class="mdi mdi-check-circle"></span></span> <%= gettext(
            "No issues found in the sample"
          ) %>
        </div>
      <% else %>
        <%= for issue <- @car.issues do %>
          <div class={"notification is-size-7 py-2 px-3 mb-2 #{if issue.severity == :error, do: "is-danger is-light", else: "is-warning is-light"}"}>
            <span class="icon is-small">
              <span class={"mdi #{if issue.severity == :error, do: "mdi-alert-circle", else: "mdi-alert"}"}>
              </span>
            </span>
             <%= issue.message %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Issue rows get a warning background; force dark text so it reads on the yellow
  # tint in both light and dark themes.
  # Per-row disposition label/class driven live by the selected mode and TM overlap.
  defp disposition(mode, tm_overlap) do
    case {mode, tm_overlap} do
      {"merge_tm", true} -> {gettext("kept (TM)"), "tag is-info is-light"}
      {"merge_tl", true} -> {gettext("replaces TM"), "tag is-danger is-light"}
      _ -> {gettext("import (TL)"), "tag is-success is-light"}
    end
  end

  ## Preview helpers

  # Blocked only when a *selected* car has no VIN that the user has supplied —
  # warnings never block, and unselected cars are irrelevant.
  defp preview_blocked?({:ok, cars}, car_vin, selected_car_ids) do
    cars
    |> Enum.filter(fn car -> MapSet.member?(selected_car_ids, car.tl_car_id) end)
    |> Enum.any?(fn car -> preview_vin(car, car_vin) == nil and car.tm_car_id == nil end)
  end

  defp preview_blocked?(_preview, _car_vin, _selected_car_ids), do: false

  defp preview_vin(car, manual_vin) do
    cond do
      car.vin not in [nil, ""] -> car.vin
      manual_vin not in [nil, ""] -> manual_vin
      true -> nil
    end
  end

  defp has_issue?(issues, ref), do: Enum.any?(issues, &(&1.ref == ref))

  defp format_naive(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M")
  end

  defp format_naive(_), do: "—"

  defp format_utc(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%MZ")
  end

  defp format_utc(_), do: missing_value()

  defp format_minutes(min) when is_integer(min), do: "#{min} min"
  defp format_minutes(_), do: missing_value()

  defp format_km(km) when is_float(km) or is_integer(km), do: "#{round(km * 10) / 10} km"
  defp format_km(_), do: missing_value()

  defp format_kwh(%Decimal{} = d), do: "#{Decimal.round(d, 1)} kWh"
  defp format_kwh(_), do: missing_value()

  defp format_cost(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  defp format_cost(_), do: missing_value()

  defp format_soc(from, to) when is_integer(from) and is_integer(to), do: "#{from} % → #{to} %"
  defp format_soc(_, _), do: missing_value()

  defp missing_value do
    Phoenix.HTML.raw(~s(<span class="has-text-grey-light">—</span>))
  end

  ## Helpers

  defp safe_to_integer(""), do: nil

  defp safe_to_integer(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp preflight_passed?(steps) do
    steps != [] and Enum.all?(steps, fn s -> s.status == :complete end)
  end

  defp preflight_step_label(:connecting), do: gettext("Connecting to MySQL")
  defp preflight_step_label(:validating_timezone), do: gettext("Validating timezone")
  defp preflight_step_label(:checking_schema), do: gettext("Checking database schema")
  defp preflight_step_label(:reading_source), do: gettext("Reading TeslaLogger data")
  defp preflight_step_label(:checking_target), do: gettext("Checking TeslaMate database")
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

  defp mode_label(:clean), do: gettext("Clean database")
  defp mode_label(:merge_tm_priority), do: gettext("Merge (TeslaMate priority)")
  defp mode_label(:merge_tl_priority), do: gettext("Merge (TeslaLogger priority)")
  defp mode_label(_), do: ""

  defp phase_label(:pending), do: ""
  defp phase_label(:reading), do: gettext("Reading MySQL…")
  defp phase_label(:mapping), do: gettext("Mapping…")
  defp phase_label(:merging_tpms), do: gettext("Merging tire pressures…")
  defp phase_label(:filtering_idle), do: gettext("Filtering idle positions…")
  defp phase_label(:validating), do: gettext("Validating…")
  defp phase_label(:filtering), do: gettext("Filtering overlaps…")
  defp phase_label(:deleting), do: gettext("Deleting overlaps…")
  defp phase_label(:inserting), do: gettext("Inserting…")
  defp phase_label(:done), do: gettext("Done")
  defp phase_label(_), do: ""

  defp phase_color(:reading), do: "has-text-info"
  defp phase_color(:mapping), do: "has-text-info"
  defp phase_color(:merging_tpms), do: "has-text-info"
  defp phase_color(:filtering_idle), do: "has-text-warning"
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

  # UTC timestamp (~2 s per Nominatim lookup) for the LocalTime hook to render in
  # the browser's local time.
  defp geocoding_finish_iso(lookups) do
    DateTime.utc_now()
    |> DateTime.add(lookups * 2, :second)
    |> DateTime.to_iso8601()
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

  defp warning_icon(:orphan_positions), do: "mdi-information-outline has-text-info"
  defp warning_icon(:drive_overlaps), do: "mdi-alert has-text-warning"
  defp warning_icon(:charge_overlaps), do: "mdi-alert has-text-warning"
  defp warning_icon(:other), do: "mdi-help-circle-outline has-text-grey"

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
