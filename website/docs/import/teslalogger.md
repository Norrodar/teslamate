---
title: Import from TeslaLogger
sidebar_label: TeslaLogger
---

## Requirements

- A running TeslaLogger instance with MySQL database access
- TeslaMate instance with PostgreSQL database
- Network access from TeslaMate to the TeslaLogger MySQL database

## Configuration

Set the following environment variables for TeslaMate:

| Variable                        | Default          | Description                          |
| ------------------------------- | ---------------- | ------------------------------------ |
| `TESLALOGGER_IMPORT`            | `false`          | Set to `true` to enable import mode  |
| `TESLALOGGER_MYSQL_HOST`        | `localhost`      | TeslaLogger MySQL hostname           |
| `TESLALOGGER_MYSQL_PORT`        | `3306`           | TeslaLogger MySQL port               |
| `TESLALOGGER_MYSQL_USER`        | `root`           | TeslaLogger MySQL username           |
| `TESLALOGGER_MYSQL_PASSWORD`    | `teslalogger`    | TeslaLogger MySQL password           |
| `TESLALOGGER_MYSQL_DATABASE`    | `teslalogger`    | TeslaLogger MySQL database name      |
| `TESLALOGGER_TIMEZONE`          | `Europe/Berlin`  | Timezone TeslaLogger was running in  |

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
      - TESLALOGGER_IMPORT=true
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

1. Start TeslaMate with the TeslaLogger import environment variables set
2. Open the TeslaMate web UI at `http://localhost:4000/import/teslalogger`
3. Optionally enter your car's VIN, EID, and VID (if TeslaLogger doesn't store them)
4. Click **Start Import**
5. Monitor the progress for each import step:
   - Cars
   - Positions
   - Drives
   - Charges
   - Charging Sessions
   - States
   - Updates
   - Geocoding
   - Validation
6. Review any validation warnings
7. After the import is complete, remove the `TESLALOGGER_IMPORT=true` variable and restart TeslaMate in normal mode

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

TeslaLogger stores timestamps in local time (MySQL `datetime` without timezone info). You must specify the timezone your TeslaLogger instance was running in via `TESLALOGGER_TIMEZONE`. All timestamps are converted to UTC during import.

## After Import

- **Geocoding**: Address lookup for drive start/end positions happens automatically in the background after import. This uses OpenStreetMap Nominatim with rate limiting (1 request/second), so it may take a while for many drives.
- **Grafana**: Check your Grafana dashboards (Trips, Charges, Statistics) to verify the imported data.
- **Normal mode**: Remove the `TESLALOGGER_IMPORT` variable and restart TeslaMate to return to normal operation.

## Troubleshooting

- **MySQL connection failed**: Ensure the MySQL host is reachable from the TeslaMate container. Check firewall rules and MySQL user permissions.
- **Missing VIN/EID/VID**: If TeslaLogger doesn't have your VIN stored, enter it manually in the import UI. The EID and VID can be placeholder values if you don't know them.
- **Large datasets**: The import uses batch processing. For databases with millions of position records, the import may take several minutes.
