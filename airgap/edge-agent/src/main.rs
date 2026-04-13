use anyhow::{Context, Result};
use rumqttc::{AsyncClient, Event, Incoming, MqttOptions, QoS};
use serde::Deserialize;
use std::env;
use std::time::Duration;
use tokio_postgres::NoTls;

#[derive(Deserialize)]
struct Reading {
    sensor_id: String,
    ts: i64,
    temperature_c: Option<f64>,
    pressure_bar: Option<f64>,
    humidity_pct: Option<f64>,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let mqtt_host = env::var("MQTT_HOST").unwrap_or_else(|_| "mosquitto".into());
    let pg_host = env::var("PG_HOST").unwrap_or_else(|_| "timescaledb".into());
    let pg_user = env::var("POSTGRES_USER").context("POSTGRES_USER")?;
    let pg_pass = env::var("POSTGRES_PASSWORD").context("POSTGRES_PASSWORD")?;
    let pg_db = env::var("POSTGRES_DB").context("POSTGRES_DB")?;

    let conn_str =
        format!("host={pg_host} user={pg_user} password={pg_pass} dbname={pg_db}");

    let pg = connect_pg_with_retry(&conn_str).await?;
    tracing::info!(%pg_host, "connected to postgres");

    let stmt = pg
        .prepare(
            "INSERT INTO readings \
             (ts, sensor_id, temperature_c, pressure_bar, humidity_pct, source) \
             VALUES (to_timestamp($1::bigint), $2, $3, $4, $5, 'rust')",
        )
        .await?;

    let client_id = env::var("HOSTNAME")
        .map(|h| format!("edge-agent-rust-{h}"))
        .unwrap_or_else(|_| "edge-agent-rust".into());
    let mut opts = MqttOptions::new(client_id, mqtt_host.clone(), 1883);
    opts.set_keep_alive(Duration::from_secs(30));
    let (client, mut eventloop) = AsyncClient::new(opts, 256);
    client.subscribe("factory/#", QoS::AtMostOnce).await?;
    tracing::info!(%mqtt_host, "subscribed to factory/#");

    let mut inserted: u64 = 0;
    loop {
        match eventloop.poll().await {
            Ok(Event::Incoming(Incoming::Publish(p))) => {
                match serde_json::from_slice::<Reading>(&p.payload) {
                    Ok(r) => {
                        match pg
                            .execute(
                                &stmt,
                                &[
                                    &r.ts,
                                    &r.sensor_id,
                                    &r.temperature_c,
                                    &r.pressure_bar,
                                    &r.humidity_pct,
                                ],
                            )
                            .await
                        {
                            Ok(_) => {
                                inserted += 1;
                                if inserted % 50 == 0 {
                                    tracing::info!(inserted, "progress");
                                }
                            }
                            Err(e) => tracing::warn!(error = %e, "insert failed"),
                        }
                    }
                    Err(e) => tracing::warn!(error = %e, topic = %p.topic, "bad json"),
                }
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!(error = %e, "mqtt loop error, retrying in 2s");
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    }
}

async fn connect_pg_with_retry(conn_str: &str) -> Result<tokio_postgres::Client> {
    for attempt in 1..=60u32 {
        match tokio_postgres::connect(conn_str, NoTls).await {
            Ok((client, connection)) => {
                tokio::spawn(async move {
                    if let Err(e) = connection.await {
                        tracing::error!(error = %e, "pg connection closed");
                    }
                });
                return Ok(client);
            }
            Err(e) => {
                tracing::info!(attempt, error = %e, "waiting for pg");
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    }
    anyhow::bail!("postgres not reachable after 120s")
}
