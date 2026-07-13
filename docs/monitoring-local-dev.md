# Local Development — Monitoring Stack

How to run the monitoring stack (Loki, Grafana, Prometheus, Alloy) locally via Dokploy without deploying application services.

## Prerequisites

- Dokploy running locally (self-hosted)
- Ports 9600 (Grafana) and 9090 (Prometheus) available

## 1. Create log volumes

The monitoring stack declares application log volumes as `external: true`. They must exist on the host before deploying through Dokploy.

```bash
docker volume create fuelrod-logs
docker volume create fees-log
docker volume create fees-dev-log
docker volume create akilimo-logs
```

## 2. Set environment variables in Dokploy

In the Dokploy UI, open the monitoring project and set these environment variables:

```
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=admin
POSTGRES_USER=grafana_user
POSTGRES_PASSWORD=changeme
POSTGRES_DB=fuelrod
```

> The PostgreSQL datasource will fail without a running database, but Grafana
> itself will start and Loki/Prometheus will function normally.

## 3. Deploy the stack

In the Dokploy UI:

1. Open the monitoring project
2. Click **Deploy** on the monitoring compose service

Monitor deployment logs in the Dokploy UI to confirm all services start.

## 4. Access services

| Service    | URL                        |
|------------|----------------------------|
| Grafana    | http://<your-dokploy-host>:9600      |
| Prometheus | http://<your-dokploy-host>:9090      |

## 5. Test log ingestion

Write a dummy log into any volume:

```bash
docker run --rm \
  -v fuelrod-logs:/var/log/fuelrod \
  alpine sh -c 'echo "2026-07-13 test fuelrod log line" > /var/log/fuelrod/test.log'

docker run --rm \
  -v fees-log:/var/log/fees \
  alpine sh -c 'echo "2026-07-13 test fees log line" > /var/log/fees/test.log'

docker run --rm \
  -v fees-dev-log:/var/log/fees-dev \
  alpine sh -c 'echo "2026-07-13 test fees-dev log line" > /var/log/fees-dev/test.log'

docker run --rm \
  -v akilimo-logs:/var/log/akilimo \
  alpine sh -c 'echo "2026-07-13 test akilimo log line" > /var/log/akilimo/test.log'
```

Wait 5-10 seconds for Alloy to pick up the files, then query in Grafana:

1. Go to Grafana → **Explore** (left sidebar)
2. Select **Loki** datasource
3. Query: `{job=~".+"}`
4. You should see log lines from all four stacks

## 6. Verify Prometheus targets

Open `http://<your-dokploy-host>:9090/targets` and confirm:

- `prometheus` — UP
- `grafana-alloy` — UP
- `caddy` — DOWN (expected if Caddy isn't running locally)

## 7. Tear down

In the Dokploy UI:

1. Open the monitoring project
2. Click **Stop** on the monitoring compose service

Optionally remove the log volumes from the host:

```bash
docker volume rm fuelrod-logs fees-log fees-dev-log akilimo-logs
```

## Troubleshooting

### Alloy shows "no such file or directory" for log paths

The log volume is empty. Write a test file into it (see step 5). The `file_match` block in `config.alloy` enables glob discovery — it will pick up new files automatically.

### Grafana datasource errors

The PostgreSQL and Redis datasources require their respective services to be running. These errors are expected in local dev if databases aren't deployed. Loki and Prometheus datasources will still work.

### Agent container exits immediately

Check logs in Dokploy UI or via terminal:

```bash
docker logs <agent-container-name>
```

Common causes:
- Missing `LOKI_URL` environment variable
- Invalid `config.alloy` syntax (check for hyphens in component labels)
- Volume mount path mismatch
