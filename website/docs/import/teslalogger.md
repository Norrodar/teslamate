---
title: Import from TeslaLogger
sidebar_label: TeslaLogger
---

## Requirements

- A running TeslaLogger instance with MySQL database access
- TeslaMate instance with PostgreSQL database
- Network access from TeslaMate to the TeslaLogger MySQL database

## Configuration

The import is configured through a guided setup in the web UI at `/import/teslalogger` —
no environment variables are required. Connection details are entered in the first
wizard step and tested before anything else happens.

Optionally, the following environment variables pre-fill the connection form
(useful for docker-compose setups):

| Variable                        | Description                          |
| ------------------------------- | ------------------------------------ |
| `TESLALOGGER_MYSQL_HOST`        | TeslaLogger MySQL hostname           |
| `TESLALOGGER_MYSQL_PORT`        | TeslaLogger MySQL port               |
| `TESLALOGGER_MYSQL_USER`        | TeslaLogger MySQL username           |
| `TESLALOGGER_MYSQL_PASSWORD`    | TeslaLogger MySQL password           |
| `TESLALOGGER_MYSQL_DATABASE`    | TeslaLogger MySQL database name      |
| `TESLALOGGER_TIMEZONE`          | Timezone TeslaLogger was running in  |

## Docker Compose Example

```yaml
services:
  teslamate:
    image: teslamate/teslamate:latest
    environment:
      - DATABASE_USER=teslamate
      - DATABASE_PASS=secret
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - MQTT_HOST=mosquitto
      - ENCRYPTION_KEY=your_encryption_key
      - TESLALOGGER_MYSQL_HOST=teslalogger-db
      - TESLALOGGER_MYSQL_PORT=3306
      - TESLALOGGER_MYSQL_USER=root
      - TESLALOGGER_MYSQL_PASSWORD=teslalogger
      - TESLALOGGER_MYSQL_DATABASE=teslalogger
      - TESLALOGGER_TIMEZONE=Europe/Berlin
    ports:
      - 4000:4000

  database:
    image: postgres:16
    environment:
      - POSTGRES_USER=teslamate
      - POSTGRES_PASSWORD=secret
      - POSTGRES_DB=teslamate

  teslalogger-db:
    image: mysql:8
    # Mount your TeslaLogger MySQL data directory
    volumes:
      - /path/to/teslalogger/mysql:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=teslalogger
      - MYSQL_DATABASE=teslalogger
```

## Usage

Open the TeslaMate web UI at `http://localhost:4000/import/teslalogger` and follow
the guided setup:

1. **Connection** — enter host, port, username, password, database, and the timezone
   your TeslaLogger was running in, then click **Test Connection**
2. **Checks** — five preflight checks run automatically: MySQL connection, timezone
   validation, schema check, source data summary, and a TeslaMate data check.
   The wizard only continues when all checks pass.
3. **Vehicles** — review the cars found in TeslaLogger (including drive/charge counts
   and date range) and optionally enter VIN, EID, and VID manually
4. **Preview** — a sample of your most recent drives and charging sessions is loaded
   and mapped exactly as the import would store it (local → UTC times, distances, SOC,
   energy, costs), including the TeslaLogger → TeslaMate car mapping. Rows the import
   would filter (phantom drives, ~0 kWh sessions) are flagged here, before anything
   is written.
5. **Mode** — choose the import mode (clean, merge with TeslaMate priority, or merge
   with TeslaLogger priority)
6. **Import** — monitor the per-step progress and review validation warnings

## What Gets Imported

| TeslaLogger Table | TeslaMate Table       | Description                    |
| ----------------- | --------------------- | ------------------------------ |
| `pos`             | `positions`           | GPS positions with telemetry   |
| `drivestate`      | `drives`              | Drive records with statistics  |
| `charging`        | `charges`             | Individual charge data points  |
| `chargingstate`   | `charging_processes`  | Charging session summaries     |
| `state`           | `states`              | Vehicle state history          |
| `car_version`     | `updates`             | Firmware update history        |

## Data Validation

The import includes automatic plausibility checks:

- **Coordinates**: Latitude must be between -90 and 90, longitude between -180 and 180
- **Battery level**: Must be between 0 and 100%
- **Speed**: Must be non-negative
- **Timestamps**: Must not be in the future
- **Drives**: Start date must be before end date, no overlapping drives
- **Charging sessions**: Start date must be before end date, no overlapping sessions
- **Energy**: Charge energy added must be non-negative

Warnings are displayed in the UI but do not block the import. Invalid records with critical errors (e.g., missing coordinates) are skipped.

## Timezone Handling

TeslaLogger stores timestamps in local time (MySQL `datetime` without timezone info). You must specify the timezone your TeslaLogger instance was running in (wizard step 1). All timestamps are converted to UTC during import. The preview step shows both the local and the converted UTC time so you can verify the conversion before importing.

## After Import

- **Geocoding**: Address lookup for drive start/end positions happens automatically in the background after import. This uses OpenStreetMap Nominatim with rate limiting (1 request/second), so it may take a while for many drives.
- **Grafana**: Check your Grafana dashboards (Trips, Charges, Statistics) to verify the imported data.

## Troubleshooting

- **MySQL connection failed**: Ensure the MySQL host is reachable from the TeslaMate container. Check firewall rules and MySQL user permissions.
- **Missing VIN/EID/VID**: If TeslaLogger doesn't have your VIN stored, enter it manually in the import UI. The EID and VID can be placeholder values if you don't know them.
- **Large datasets**: The import uses batch processing. For databases with millions of position records, the import may take several minutes.
