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

## Get the agent token

Each app has one agent token (`g8a_…`). You get it when you create the app in
the g8te portal, or when you issue a new one on the app's page, in one of two
ways:

- **Shown once on screen**, together with a ready-to-run `docker run` command.
  Copy it into a secret store or the project's `.env` right away.
- **Through a one-time setup code** (`g8s_…`), for setting up with a coding
  agent (Claude Code, Cursor, …). The portal gives you a setup prompt, with a
  copy and a download button, that contains the code instead of the token,
  because prompts end up in chat histories. The prompt has the coding agent run
  this once, in the directory that holds the project's `.env`:

  ```sh
  curl -fsS -X POST https://apps.example.com/api/agent/v1/setup -d code=g8s_… >> .env
  ```

  The portal answers with a `G8TE_TOKEN=g8a_…` line, which is appended to
  `.env` without being printed. A setup code works once, expires after 24
  hours, and stops working when a new agent token is issued. If it has been
  used or has expired, the command fails and writes nothing; issue a new token
  on the app's page to get a fresh prompt.

Through g8te's API or MCP server, creating an app returns the token directly,
along with the same setup prompt.

Keep `.env` out of version control. Anyone holding the token can connect a
tunnel for your app; if it may have leaked, issue a new one on the app's page
(the old one stops working at once).

## Run it

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
      G8TE_TOKEN: ${G8TE_TOKEN}   # from the project's .env (see above)
      G8TE_UPSTREAM: http://web:3000
```

Docker Compose reads `G8TE_TOKEN` from the `.env` file next to
`docker-compose.yml`, which is where the setup code command puts it. To use a
Docker secret instead, set `G8TE_TOKEN_FILE`:

```yaml
  g8te-agent:
    image: ghcr.io/xtr-dev/g8te-agent:latest
    environment:
      G8TE_PORTAL: https://apps.example.com
      G8TE_TOKEN_FILE: /run/secrets/g8te_token
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
| `G8TE_TCP_HOST` | Where raw TCP ports lead (default: the host of `G8TE_UPSTREAM`). See below. |
| `G8TE_PORTAL_CA` | Extra CA bundle for reaching the portal, for test setups with private certificates. |

## TCP ports (SSH and the like)

For a service that doesn't speak HTTP, such as SSH for a git server, a g8te
platform admin can give the app public TCP ports, each leading to a local port.
The agent picks them up from its configuration by itself and forwards public
port → `G8TE_TCP_HOST:local port`. For Gitea, which serves web and SSH from one
container, `G8TE_UPSTREAM=http://gitea:3000` is enough: the admin assigns, say,
public port 2200 → local port 22, and users run `ssh -p 2200 git@<tunnel host>`.

Connections on these ports don't pass g8te's sign-in. The service behind the
port must authenticate on its own (SSH: keys only).

## Network and security

- Outgoing only: HTTPS to the portal, and TCP port 7000 to the g8te tunnel
  host (from the portal's configuration). Nothing listens for incoming
  connections.
- The tunnel is TLS-encrypted, and the agent trusts only the g8te server's
  own certificate authority, which it receives from the portal. It can't be
  redirected to an impostor.
- The agent can only register its own app's route, plus TCP ports a g8te
  platform admin assigned to the app; g8te refuses anything else.
- If the portal rejects the token (rotated or revoked), the agent stops its
  tunnel until it gets a valid token.
- The container runs as an unprivileged user.

## Troubleshooting

| Log message | Cause |
|---|---|
| `cannot fetch configuration … token rejected or portal unreachable` | Wrong `G8TE_PORTAL`, or the token was replaced; issue a new one on the app's page. |
| `connect to server error: dial tcp …:7000: i/o timeout` | Port 7000 to the tunnel host is blocked by a firewall. |
| `token rejected by the portal; stopping the tunnel` | The token was rotated or the app deleted. |
| The setup code command fails with `410` (*unknown, already used or expired*) | Each code works once, for 24 hours, and only until a new token is issued. Issue a new agent token on the app's page for a fresh setup prompt. |
| `G8TE_TOKEN` is empty after running the setup code command | The command ran in another directory; `.env` must be next to `docker-compose.yml`. |
| The token is rejected right after setting up | `.env` still has an older `G8TE_TOKEN=` line; keep only the newest one. |

When the agent is connected, the app shows as **connected** in the portal.
More in g8te's [guide for connecting an app](https://github.com/xtr-dev/g8te/blob/main/docs/connect-an-app.md).

## Releases

Every push to `main` publishes `ghcr.io/xtr-dev/g8te-agent:latest` (amd64 and
arm64); tags `vX.Y.Z` also publish `:X.Y.Z` and `:X.Y`. The frp version is
pinned in the `Dockerfile`; g8te's server runs the same frp version.
