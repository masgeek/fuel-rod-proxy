# EMQX MQTT

The MQTT stack runs EMQX on the host and exposes its listeners locally:

| Listener | Host endpoint | Purpose |
|---|---|---|
| MQTT TCP | `127.0.0.1:1883` | Internal PHP publishers such as `fee-syncer` |
| MQTT WebSocket | `127.0.0.1:8083` | Backend for the public WSS endpoint |
| Dashboard | `127.0.0.1:18083` | EMQX administration |

The public Agent endpoint is:

```text
wss://mqtt.munywele.co.ke/mqtt
```

## Caddy Routing

Copy the block in `stacks/mqtt/Caddyfile` into the active host Caddyfile. The
`/mqtt` matcher must be evaluated before the dashboard fallback:

```caddyfile
mqtt.munywele.co.ke {
    @mqtt path /mqtt /mqtt/*
    handle @mqtt {
        reverse_proxy http://127.0.0.1:8083
    }

    handle {
        reverse_proxy http://127.0.0.1:18083
    }
}
```

Caddy handles the WebSocket upgrade automatically. Reload after validation:

```bash
caddy validate --config /etc/caddy/Caddyfile
sudo caddy reload --config /etc/caddy/Caddyfile
```

## FeeSyncer Agent

Configure the Agent with:

```json
{
  "MqttBrokerHost": "wss://mqtt.munywele.co.ke/mqtt",
  "MqttBrokerPort": 443,
  "MqttBrokerPath": "/mqtt",
  "MqttUseTls": true
}
```

## Troubleshooting

The MQTT WebSocket handshake must return HTTP `101 Switching Protocols`.
HTTP `200` means `/mqtt` was routed to the EMQX dashboard or another HTTP
application instead of the WebSocket listener. Check Caddy handler order and
confirm EMQX is listening on `127.0.0.1:8083`.
