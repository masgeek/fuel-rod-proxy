# Local Development — Monitoring Stack

How to run the monitoring stack (Loki, Grafana, Prometheus, Alloy) locally via Dokploy without deploying application services.

## Prerequisites

- Dokploy running locally (self-hosted)
- Ports 9600 (Grafana) and 9090 (Prometheus) available

## 1. Verify Docker socket access

Alloy discovers application containers through the Docker socket. Confirm it
exists on the deployment host:

```bash
test -S /var/run/docker.sock
```

## 2. Set environment variables in Dokploy

In the Dokploy UI, open the monitoring project and set these environment variables:

```
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=admin
```

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

Application logs are read from Docker stdout. Generate test entries with:

```bash
docker exec fuelrod php artisan tinker --execute="logger()->warning('test fuelrod log line');"
docker exec fee.prod php artisan tinker --execute="logger()->warning('test fees log line');"
docker exec fee.dev php artisan tinker --execute="logger()->warning('test fees-dev log line');"
docker exec akilimo-api php artisan tinker --execute="logger()->warning('test akilimo log line');"
```

Wait 5-10 seconds for Alloy to collect the entries, then query in Grafana:

1. Go to Grafana → **Explore** (left sidebar)
2. Select **Loki** datasource
3. Query: `{log_type="container", service_name=~"fuelrod-sms|fees|fees-dev|akilimo"}`
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

## Troubleshooting

### Alloy cannot discover containers

Confirm `/var/run/docker.sock` is mounted in the Alloy container and that Alloy
can read it. Review the `discovery.docker` component on Alloy's debug page.

### Alloy container exits immediately

Check logs in Dokploy UI or via terminal:

```bash
docker logs <agent-container-name>
```

Common causes:
- Missing `LOKI_URL` environment variable
- Invalid `config.alloy` syntax (check for hyphens in component labels)
- Docker socket permission or mount errors
