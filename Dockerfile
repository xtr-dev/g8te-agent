# The g8te agent: frpc plus a small supervisor that fetches its configuration
# from the portal. Runs next to an app and keeps a tunnel to g8te open.
#
#   docker run -e G8TE_PORTAL=https://apps.example.com -e G8TE_TOKEN=g8a_… \
#              -e G8TE_UPSTREAM=http://web:3000 ghcr.io/xtr-dev/g8te-agent
FROM fatedier/frpc:v0.71.0

RUN apk add --no-cache curl jq ca-certificates tini
COPY entrypoint.sh /usr/local/bin/g8te-agent
RUN chmod +x /usr/local/bin/g8te-agent \
 && adduser -D -H -u 10001 agent
USER agent
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/g8te-agent"]
