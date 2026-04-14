use anyhow::{Context, Result};
use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use lazy_static::lazy_static;
use prometheus::{
    register_counter_vec, register_gauge_vec, register_histogram_vec, CounterVec, Encoder,
    GaugeVec, HistogramOpts, HistogramVec, TextEncoder,
};
use rumqttc::{AsyncClient, Event, Incoming as MqttIn, MqttOptions, QoS};
use serde::Deserialize;
use std::convert::Infallible;
use std::env;
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio_postgres::NoTls;

const SOURCE: &str = "rust";
const BUCKETS: &[f64] = &[
    0.0005, 0.001, 0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0,
];

lazy_static! {
    static ref MSGS: CounterVec = register_counter_vec!(
        "bridge_messages_total",
        "messages handled",
        &["source", "result"]
    )
    .unwrap();
    static ref INSERT_LAT: HistogramVec = register_histogram_vec!(
        HistogramOpts::new("bridge_insert_duration_seconds", "DB insert latency")
            .buckets(BUCKETS.to_vec()),
        &["source"]
    )
    .unwrap();
    static ref PARSE_LAT: HistogramVec = register_histogram_vec!(
        HistogramOpts::new("bridge_parse_duration_seconds", "JSON parse latency")
            .buckets(BUCKETS.to_vec()),
        &["source"]
    )
    .unwrap();
    static ref IN_FLIGHT: GaugeVec = register_gauge_vec!(
        "bridge_in_flight",
        "messages currently being processed",
        &["source"]
    )
    .unwrap();
}

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

    // Touch metrics so they show up in /metrics before the first message.
    MSGS.with_label_values(&[SOURCE, "ok"]).reset();
    MSGS.with_label_values(&[SOURCE, "error"]).reset();
    IN_FLIGHT.with_label_values(&[SOURCE]).set(0.0);

    tokio::spawn(async {
        if let Err(e) = run_metrics_server().await {
            tracing::error!(error = %e, "metrics server died");
        }
    });

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
    let (client, mut eventloop) = AsyncClient::new(opts, 1024);
    client.subscribe("factory/#", QoS::AtMostOnce).await?;
    tracing::info!(%mqtt_host, "subscribed to factory/#");

    let mut inserted: u64 = 0;
    loop {
        match eventloop.poll().await {
            Ok(Event::Incoming(MqttIn::Publish(p))) => {
                IN_FLIGHT.with_label_values(&[SOURCE]).inc();

                let parse_t = Instant::now();
                let parsed = serde_json::from_slice::<Reading>(&p.payload);
                PARSE_LAT
                    .with_label_values(&[SOURCE])
                    .observe(parse_t.elapsed().as_secs_f64());

                match parsed {
                    Ok(r) => {
                        let insert_t = Instant::now();
                        let res = pg
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
                            .await;
                        INSERT_LAT
                            .with_label_values(&[SOURCE])
                            .observe(insert_t.elapsed().as_secs_f64());

                        match res {
                            Ok(_) => {
                                MSGS.with_label_values(&[SOURCE, "ok"]).inc();
                                inserted += 1;
                                if inserted % 500 == 0 {
                                    tracing::info!(inserted, "progress");
                                }
                            }
                            Err(e) => {
                                MSGS.with_label_values(&[SOURCE, "error"]).inc();
                                tracing::warn!(error = %e, "insert failed");
                            }
                        }
                    }
                    Err(e) => {
                        MSGS.with_label_values(&[SOURCE, "error"]).inc();
                        tracing::warn!(error = %e, topic = %p.topic, "bad json");
                    }
                }

                IN_FLIGHT.with_label_values(&[SOURCE]).dec();
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

async fn metrics_handler(
    _req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let encoder = TextEncoder::new();
    let mut buf = Vec::new();
    let metric_families = prometheus::gather();
    encoder.encode(&metric_families, &mut buf).unwrap();
    Ok(Response::builder()
        .header("content-type", encoder.format_type())
        .body(Full::new(Bytes::from(buf)))
        .unwrap())
}

async fn run_metrics_server() -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", 9090)).await?;
    tracing::info!("metrics server on :9090/metrics");
    loop {
        let (stream, _) = listener.accept().await?;
        let io = TokioIo::new(stream);
        tokio::spawn(async move {
            if let Err(e) = http1::Builder::new()
                .serve_connection(io, service_fn(metrics_handler))
                .await
            {
                tracing::warn!(error = %e, "metrics conn");
            }
        });
    }
}
