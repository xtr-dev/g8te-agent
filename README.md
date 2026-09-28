# g8te agent

Connects a web app to a [g8te](https://github.com/xtr-dev/g8te) gate. The
agent runs next to your app, dials out to g8te and keeps a tunnel open, so
your app gets a public HTTPS address behind g8te's sign-in gate without any
open port on the machine it runs on.

```
browser ──HTTPS──▶ g8te (checks who may open the app) ──tunnel──▶ g8te agent ──▶ your app
```

It is [frpc](https://github.com/fatedier/frp) plus a small supervisor: the
agent fetches its tunnel configuration from your g8te portal with its agent
token, and restarts the tunnel when that configuration changes (for example
when the app moves to another domain).

## Run it

You get the agent token (`g8a_…`) when you create an app in the g8te portal
(or through its API or MCP server).

```sh
docker run -d --name g8te-agent --restart unless-stopped \
  --add-host host.docker.internal:host-gateway \
  -e G8TE_PORTAL=https://apps.example.com \
  -e G8TE_TOKEN=g8a_your_token \
  -e G8TE_UPSTREAM=http://host.docker.internal:3000 \
  ghcr.io/xtr-dev/g8te-agent:latest
```

`host.docker.internal` reaches a port on the Docker host. If your app runs in
a container, put the agent on the same Docker network and use the container
name instead:

```yaml
services:
  web:
    image: your-app
  g8te-agent:
    image: ghcr.io/xtr-dev/g8te-agent:latest
    restart: unless-stopped
    environment:
      G8TE_PORTAL: https://apps.example.com
      G8TE_TOKEN_FILE: /run/secrets/g8te_token   # or G8TE_TOKEN: g8a_…
      G8TE_UPSTREAM: http://web:3000
    secrets: [g8te_token]
secrets:
  g8te_token:
    file: ./g8te_token.txt
```

## Settings

| Variable | Meaning |
|---|---|
| `G8TE_PORTAL` | Your g8te portal, e.g. `https://apps.example.com` (required). |
| `G8TE_TOKEN` | The app's agent token (required, or `G8TE_TOKEN_FILE`). |
| `G8TE_TOKEN_FILE` | A file containing the token, e.g. a Docker secret. It is re-read, so replacing it switches tokens without a restart. |
| `G8TE_UPSTREAM` | Where the agent finds your app: `http://host:port` (required; plain HTTP). |
| `G8TE_POLL_SECONDS` | How often to check for configuration changes (default 60). |
| `G8TE_PORTAL_CA` | Extra CA bundle for reaching the portal, for test setups with private certificates. |

## Network and security

- Outgoing only: HTTPS to the portal, and TCP port 7000 to the g8te tunnel
  host (from the portal's configuration). Nothing listens for incoming
  connections.
- The tunnel is TLS-encrypted, and the agent trusts only the g8te server's
  own certificate authority, which it receives from the portal. It can't be
  redirected to an impostor.
- The agent can only register its own app's route; g8te refuses anything else.
- If the portal rejects the token (rotated or revoked), the agent stops its
  tunnel until it gets a valid token.
- The container runs as an unprivileged user.

## Troubleshooting

| Log message | Cause |
|---|---|
| `cannot fetch configuration … token rejected or portal unreachable` | Wrong `G8TE_PORTAL`, or the token was replaced; issue a new one on the app's page. |
| `connect to server error: dial tcp …:7000: i/o timeout` | Port 7000 to the tunnel host is blocked by a firewall. |
| `token rejected by the portal; stopping the tunnel` | The token was rotated or the app deleted. |

When the agent is connected, the app shows as **connected** in the portal.
More in g8te's [guide for connecting an app](https://github.com/xtr-dev/g8te/blob/main/docs/connect-an-app.md).

## Releases

Every push to `main` publishes `ghcr.io/xtr-dev/g8te-agent:latest` (amd64 and
arm64); tags `vX.Y.Z` also publish `:X.Y.Z` and `:X.Y`. The frp version is
pinned in the `Dockerfile`; g8te's server runs the same frp version.
