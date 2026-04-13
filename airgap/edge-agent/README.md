# edge-agent (Rust)

MQTT → TimescaleDB bridge. Drop-in replacement for the Python `mqtt-tsdb-bridge` in `../k8s/edge-demo/40-bridge.yaml`.

## Interface (matches existing pipeline)

- Subscribes to `factory/#` on `mosquitto:1883`
- Payload: `{sensor_id, ts (unix epoch), temperature_c, pressure_bar, humidity_pct}`
- Inserts into `readings` hypertable on `timescaledb:5432` / db `sensors`
- Env: `MQTT_HOST`, `PG_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`

## Build

See [`../docs/RUST-OFFLINE-BUILD.md`](../docs/RUST-OFFLINE-BUILD.md) for the airgap vendor/build procedure.

Local (online) quickstart:
```
cargo run
```

## Why Rust here

Narrative: single static binary ~10 MB, RSS ~5 MB, no GC pauses. `kubectl top pod -n edge-demo` shows the delta vs the Python bridge.
