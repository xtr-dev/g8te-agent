#!/bin/sh
# g8te agent supervisor.
#
# Fetches this app's tunnel configuration from the portal, writes frpc.toml,
# runs frpc, and checks the configuration every G8TE_POLL_SECONDS: when it
# changes (new hostname, rotated routing key), frpc is restarted with the new
# settings. Everything except the token and the upstream comes from the portal.
#
# Environment:
#   G8TE_PORTAL        portal URL, e.g. https://apps.example.com (required)
#   G8TE_TOKEN         agent token g8a_… (required, or G8TE_TOKEN_FILE)
#   G8TE_TOKEN_FILE    file containing the token (e.g. a Docker secret); waited for if missing
#   G8TE_UPSTREAM      the app, e.g. http://web:3000 (required; http only)
#   G8TE_TCP_HOST      where TCP ports assigned by a g8te admin lead (default: the upstream's host)
#   G8TE_PORTAL_CA     optional CA bundle for reaching the portal (test setups)
#   G8TE_POLL_SECONDS  how often to check for configuration changes (default 60)
set -eu

log() { echo "g8te-agent: $*" >&2; }

: "${G8TE_PORTAL:?G8TE_PORTAL is required, e.g. https://apps.example.com}"
: "${G8TE_UPSTREAM:?G8TE_UPSTREAM is required, e.g. http://web:3000}"
POLL="${G8TE_POLL_SECONDS:-60}"
WORK="${TMPDIR:-/tmp}/g8te-agent"
mkdir -p "$WORK"

token() {
    if [ -n "${G8TE_TOKEN:-}" ]; then
        printf '%s' "$G8TE_TOKEN"
    elif [ -n "${G8TE_TOKEN_FILE:-}" ]; then
        while [ ! -s "$G8TE_TOKEN_FILE" ]; do
            log "waiting for token file $G8TE_TOKEN_FILE"
            sleep 2
        done
        tr -d '\r\n ' < "$G8TE_TOKEN_FILE"
    else
        log "G8TE_TOKEN or G8TE_TOKEN_FILE is required"
        exit 64
    fi
}

# Split G8TE_UPSTREAM (http://host:port) into host and port for frpc.
case "$G8TE_UPSTREAM" in
    http://*) upstream="${G8TE_UPSTREAM#http://}" ;;
    *) log "G8TE_UPSTREAM must start with http:// (TLS to the app is not supported)"; exit 64 ;;
esac
upstream="${upstream%%/*}"
UPSTREAM_HOST="${upstream%:*}"
UPSTREAM_PORT="${upstream##*:}"
[ "$UPSTREAM_PORT" = "$upstream" ] && UPSTREAM_PORT=80
TCP_HOST="${G8TE_TCP_HOST:-$UPSTREAM_HOST}"

# Fetches the configuration. Returns 0 on success, 2 when the portal rejects
# the token (revoked or rotated), 1 on any other failure (network, portal down).
fetch_config() {
    set -- -sS --max-time 20 -o "$WORK/config.json.new" -w '%{http_code}' -H "Authorization: Bearer $TOKEN"
    [ -n "${G8TE_PORTAL_CA:-}" ] && set -- "$@" --cacert "$G8TE_PORTAL_CA"
    status="$(curl "$@" "${G8TE_PORTAL%/}/api/agent/v1/config" || echo 000)"
    case "$status" in
        200) mv "$WORK/config.json.new" "$WORK/config.json"; return 0 ;;
        401|403) return 2 ;;
        *) return 1 ;;
    esac
}

write_frpc_config() {
    jq -r '.ca_pem' "$WORK/config.json" > "$WORK/ca.pem"
    jq -r \
        --arg token "$TOKEN" \
        --arg ca "$WORK/ca.pem" \
        --arg upstream_host "$UPSTREAM_HOST" \
        --arg tcp_host "$TCP_HOST" \
        --argjson upstream_port "$UPSTREAM_PORT" '
        "serverAddr = \(.server_addr | tojson)\n" +
        "serverPort = \(.server_port)\n" +
        "loginFailExit = false\n" +
        "auth.method = \"token\"\n" +
        "auth.token = \(.auth_token | tojson)\n" +
        "metadatas.token = \($token | tojson)\n" +
        "transport.tls.enable = true\n" +
        "transport.tls.trustedCaFile = \($ca | tojson)\n" +
        "transport.tls.serverName = \(.server_name | tojson)\n" +
        "transport.heartbeatInterval = \(.heartbeat_interval)\n" +
        "transport.heartbeatTimeout = \(.heartbeat_timeout)\n" +
        "log.to = \"console\"\n\n" +
        "[[proxies]]\n" +
        "name = \(.proxy_name | tojson)\n" +
        "type = \"http\"\n" +
        "localIP = \($upstream_host | tojson)\n" +
        "localPort = \($upstream_port)\n" +
        "customDomains = [\(.routing_key | tojson)]\n" +
        "hostHeaderRewrite = \(.host_header | tojson)\n" +
        # Raw TCP ports a g8te platform admin assigned to the app (for example SSH).
        ([(.tcp_ports // [])[] |
            "\n[[proxies]]\n" +
            "name = \(.proxy_name | tojson)\n" +
            "type = \"tcp\"\n" +
            "localIP = \($tcp_host | tojson)\n" +
            "localPort = \(.local_port)\n" +
            "remotePort = \(.remote_port)\n"
        ] | join(""))
    ' "$WORK/config.json" > "$WORK/frpc.toml"
}

TOKEN="$(token)"
until fetch_config; do
    log "cannot fetch configuration from $G8TE_PORTAL (token rejected or portal unreachable); retrying in 10s"
    sleep 10
    [ -z "${G8TE_TOKEN:-}" ] && TOKEN="$(token)"
done

FRPC_PID=""
stop_frpc() {
    if [ -n "$FRPC_PID" ]; then
        kill "$FRPC_PID" 2>/dev/null || true
        wait "$FRPC_PID" 2>/dev/null || true
        FRPC_PID=""
    fi
}
trap 'stop_frpc; exit 0' TERM INT

start_frpc() {
    write_frpc_config
    frpc -c "$WORK/frpc.toml" &
    FRPC_PID=$!
    CURRENT_ETAG="$(jq -r '.etag' "$WORK/config.json")"
    log "tunnel started for app $(jq -r '.app' "$WORK/config.json") (upstream $UPSTREAM_HOST:$UPSTREAM_PORT)"
    jq -r '(.tcp_ports // [])[] | "\(.remote_port) \(.local_port)"' "$WORK/config.json" | while read -r remote local; do
        log "TCP port $remote on the g8te server leads to $TCP_HOST:$local"
    done
}

start_frpc
while true; do
    sleep "$POLL" &
    wait $! || true
    # A token file may be replaced (rotated token); pick up the new token without a restart.
    if [ -z "${G8TE_TOKEN:-}" ] && [ -n "${G8TE_TOKEN_FILE:-}" ]; then
        NEW_TOKEN="$(token)"
        if [ "$NEW_TOKEN" != "$TOKEN" ]; then
            log "token file changed"
            TOKEN="$NEW_TOKEN"
            CURRENT_ETAG=""
        fi
    fi
    result=0
    fetch_config || result=$?
    case "$result" in
        0)
            if [ -z "$FRPC_PID" ] || ! kill -0 "$FRPC_PID" 2>/dev/null || [ "$(jq -r '.etag' "$WORK/config.json")" != "$CURRENT_ETAG" ]; then
                log "starting tunnel with current configuration"
                stop_frpc
                start_frpc
            fi
            ;;
        2)
            # The token was revoked or rotated: stop serving until a valid token arrives.
            if [ -n "$FRPC_PID" ]; then
                log "token rejected by the portal; stopping the tunnel"
                stop_frpc
            fi
            ;;
        *)
            # Portal unreachable: keep the tunnel as it is; it doesn't depend on the portal.
            log "configuration check failed (keeping the current tunnel)"
            ;;
    esac
done
