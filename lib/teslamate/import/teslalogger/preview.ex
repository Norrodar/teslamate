defmodule TeslaMate.Import.TeslaLogger.Preview do
  @moduledoc false

  # Builds a per-car sample of mapped data ("this is what your data would look
  # like") for the wizard preview step. Runs the real read→map→enrich pipeline
  # on the most recent drives and charging sessions, then flags rows the import
  # would later filter or that look suspicious.

  alias TeslaMate.Import.TeslaLogger.{Mapper, MysqlReader, Writer}

  @sample_limit 5

  @doc """
  Builds the preview for one TeslaLogger car.
  `car_info` is the preflight-enriched map (id, vin, display_name, tm_car_id, ...).
  Returns {:ok, preview_map} or {:error, reason}.
  """
  def build(conn, car_info, timezone) do
    tl_car_id = car_info["id"]
    tm_car_id = car_info["tm_car_id"]

    # Existing TeslaMate ranges for the matched car — used to mark each sample row
    # as overlapping TM data (so the UI can show "kept/replaced/imported" per mode).
    tm_drive_ranges = if tm_car_id, do: Writer.load_existing_ranges(tm_car_id, :drives), else: []

    tm_charge_ranges =
      if tm_car_id, do: Writer.load_existing_ranges(tm_car_id, :charging_processes), else: []

    with {:ok, drive_rows} <- MysqlReader.read_recent_drives(conn, tl_car_id, @sample_limit),
         {:ok, cp_rows} <-
           MysqlReader.read_recent_charging_sessions(conn, tl_car_id, @sample_limit) do
      drives =
        Enum.map(drive_rows, fn row ->
          d = build_drive(conn, row, timezone)
          Map.put(d, :tm_overlap, overlaps_tm?(d, tm_drive_ranges))
        end)

      charges =
        Enum.map(cp_rows, fn row ->
          c = build_charge(conn, tl_car_id, row, timezone)
          Map.put(c, :tm_overlap, overlaps_tm?(c, tm_charge_ranges))
        end)

      preview = %{
        tl_car_id: tl_car_id,
        display_name: car_info["display_name"],
        vin: car_info["vin"],
        tm_car_id: tm_car_id,
        drives: drives,
        charges: charges,
        issues: detect_issues(car_info, drives, charges)
      }

      {:ok, preview}
    end
  end

  # A row overlaps TeslaMate when its time range intersects an existing TM range.
  defp overlaps_tm?(%{start_date: nil}, _ranges), do: false
  defp overlaps_tm?(_row, []), do: false
  defp overlaps_tm?(row, ranges), do: Writer.filter_non_overlapping([row], ranges) == []

  # Mirrors the import pipeline: map_drive + enrich with the TL boundary positions
  # (StartPos/EndPos provide odometer and ranges — enough for the preview).
  defp build_drive(conn, row, timezone) do
    attrs = Mapper.map_drive(row, timezone)

    pos_ids = Enum.reject([row["StartPos"], row["EndPos"]], &is_nil/1)

    boundary_positions =
      case MysqlReader.read_positions_by_ids(conn, pos_ids) do
        {:ok, pos_rows} -> Enum.map(pos_rows, &Mapper.map_position(&1, timezone))
        {:error, _} -> []
      end

    attrs
    |> Mapper.enrich_drive(boundary_positions)
    |> Map.merge(%{tl_id: row["id"], start_date_local: row["StartDate"]})
  end

  # Mirrors the import pipeline: map_charging_process + per-session charges with
  # DC correction + enrichment (SOC, energy used, ranges).
  defp build_charge(conn, tl_car_id, row, timezone) do
    attrs = Mapper.map_charging_process(row, timezone)

    session_charges =
      case MysqlReader.read_charges_in_range(conn, tl_car_id, row["StartDate"], row["EndDate"]) do
        {:ok, charge_rows} ->
          charge_rows
          |> Enum.map(&Mapper.map_charge(&1, timezone))
          |> Mapper.correct_dc_classification()

        {:error, _} ->
          []
      end

    attrs
    |> Mapper.enrich_charging_process(session_charges)
    |> Map.merge(%{tl_id: row["id"], start_date_local: row["StartDate"]})
  end

  @doc """
  Flags rows the import would filter (phantoms, zero-duration) and values that
  look wrong — so problems surface BEFORE the import runs, not during.
  Public for testing; `build/3` calls it with mapped drives/charges.
  """
  def detect_issues(car_info, drives, charges) do
    car_issues(car_info) ++
      Enum.flat_map(drives, &drive_issues/1) ++
      Enum.flat_map(charges, &charge_issues/1)
  end

  defp car_issues(car_info) do
    if car_info["vin"] in [nil, ""] do
      [
        issue(
          :error,
          :car,
          "No VIN in TeslaLogger — the import aborts unless you enter one manually"
        )
      ]
    else
      []
    end
  end

  defp drive_issues(drive) do
    label = "Drive #{format_date(drive.start_date_local)}"
    distance = drive[:distance]
    duration = drive[:duration_min]

    cond do
      is_nil(drive.start_date) ->
        [
          issue(
            :warning,
            {:drive, drive.tl_id},
            "#{label}: timezone conversion failed — would be skipped"
          )
        ]

      is_nil(distance) ->
        [
          issue(
            :warning,
            {:drive, drive.tl_id},
            "#{label}: no position data — would be filtered as phantom drive"
          )
        ]

      distance <= 0 ->
        [
          issue(
            :warning,
            {:drive, drive.tl_id},
            "#{label}: no movement — would be filtered as phantom drive"
          )
        ]

      distance < 0.5 and is_number(duration) and duration < 2 ->
        [
          issue(
            :warning,
            {:drive, drive.tl_id},
            "#{label}: micro-movement — would be filtered as phantom drive"
          )
        ]

      distance > 2000 ->
        [
          issue(
            :warning,
            {:drive, drive.tl_id},
            "#{label}: #{round(distance)} km in one drive — check odometer data"
          )
        ]

      true ->
        []
    end
  end

  defp charge_issues(cp) do
    label = "Charge #{format_date(cp.start_date_local)}"
    energy = cp[:charge_energy_added]

    cond do
      is_nil(cp.start_date) ->
        [
          issue(
            :warning,
            {:charge, cp.tl_id},
            "#{label}: timezone conversion failed — would be skipped"
          )
        ]

      is_nil(energy) or Decimal.compare(energy, Decimal.from_float(0.1)) != :gt ->
        [
          issue(
            :warning,
            {:charge, cp.tl_id},
            "#{label}: ~0 kWh added — would be filtered as phantom session"
          )
        ]

      is_nil(cp[:start_battery_level]) ->
        [
          issue(
            :warning,
            {:charge, cp.tl_id},
            "#{label}: no charge rows found — SOC and energy used stay empty"
          )
        ]

      true ->
        []
    end
  end

  defp issue(severity, ref, message), do: %{severity: severity, ref: ref, message: message}

  defp format_date(%NaiveDateTime{} = ndt), do: ndt |> NaiveDateTime.to_date() |> Date.to_string()
  defp format_date(_), do: "?"
end
