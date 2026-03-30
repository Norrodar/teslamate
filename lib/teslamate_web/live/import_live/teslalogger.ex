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
      end

      status = TLImport.get_status()

      socket =
        socket
        |> assign(status: status)
        |> assign(page_title: gettext("TeslaLogger Import"))
        |> assign(car_vin: "")
        |> assign(car_eid: "")
        |> assign(car_vid: "")

      {:ok, socket}
    else
      {:ok, redirect(socket, to: Routes.car_path(socket, :index))}
    end
  end

  @impl true
  def handle_event("start_import", _params, socket) do
    car_mapping =
      case {socket.assigns.car_vin, socket.assigns.car_eid, socket.assigns.car_vid} do
        {"", "", ""} ->
          %{}

        {vin, eid, vid} ->
          eid_int = safe_to_integer(eid)
          vid_int = safe_to_integer(vid)

          # Map for TeslaLogger car ID 1 (most common single-car setup)
          %{1 => %{vin: if(vin != "", do: vin), eid: eid_int, vid: vid_int}}
      end

    :ok = TLImport.run(car_mapping)
    {:noreply, assign(socket, status: %Status{socket.assigns.status | state: :running})}
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

  defp format_progress(step) do
    if step.total > 0 do
      "#{step.imported}/#{step.total}"
    else
      ""
    end
  end
end
