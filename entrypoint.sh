#!/usr/bin/env bash
set -uo pipefail
DATA=/var/lib/pasarguard
mkdir -p "$DATA/node-certs" /var/lib/pg-node
# Railway may hand the service its own PORT; CHOST always answers on 8080 AND on that port,
# so the domain and the health check work in every region whatever the target port is
RW_PORT="${PORT:-8080}"
case "$RW_PORT" in ''|*[!0-9]*) RW_PORT=8080 ;; esac
case "$RW_PORT" in 8000|8100|62050|1000[1-6]) RW_PORT=8080 ;; esac   # never clash with the internal ports
export PORT=8080

# owner admin/admin is written by bootstrap.py on FIRST boot only
unset SUDO_USERNAME SUDO_PASSWORD

# ---- node secrets: generated once, kept on the volume ----
[ -f "$DATA/node_api_key" ] || python -c "import uuid;print(uuid.uuid4())" > "$DATA/node_api_key"
if [ ! -f "$DATA/node-certs/cert.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
fi

# ---- unique config paths for this install (kept on the volume) ----
python /code/genpaths.py || exit 1

# ---- nginx ----
EXTRA=""
if [ "$RW_PORT" != "8080" ]; then EXTRA="listen ${RW_PORT}; listen [::]:${RW_PORT};"; fi
sed -e "s/__PORT__/${PORT}/g" -e "s/#__EXTRA_LISTEN__/${EXTRA}/" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
if [ ! -s /proc/net/if_inet6 ]; then
  # region without IPv6 inside the container: listen on IPv4 only instead of failing to start
  sed -i 's/listen \[::\]:[0-9]*[^;]*;//g' /etc/nginx/nginx.conf
  echo "[chost] IPv6 not available here, listening on IPv4 only"
fi
if ! nginx -t 2>/tmp/nginx-test.log; then
  # never fail the deploy because of IPv6: retry on IPv4 only
  sed -i 's/listen \[::\]:[0-9]*[^;]*;//g' /etc/nginx/nginx.conf
  if ! nginx -t; then cat /tmp/nginx-test.log; echo "[chost] nginx config error"; exit 1; fi
  echo "[chost] IPv6 listen failed here, using IPv4 only"
fi
echo "[chost] listening on 8080${EXTRA:+ and ${RW_PORT}}"
echo "[chost] region: ${RAILWAY_REPLICA_REGION:-unknown}, domain: ${RAILWAY_PUBLIC_DOMAIN:-not generated yet}"

# ---- every part runs under its own supervisor: if one part stops, only that part is started again
#      (in a few seconds, inside the same container). The service itself is never restarted. ----
supervise() {   # supervise <name> <pidfile> <command...>
  local name="$1" pidf="$2"; shift 2; local n=0
  while true; do
    "$@" &
    echo $! > "$pidf"
    wait $! ; code=$?
    n=$((n+1))
    echo "[chost] $name stopped (exit $code), starting it again (#$n)"
    sleep $(( n < 5 ? 2 : 10 ))
  done
}

# ---- node (xray) ----
node_run() {
  cd /opt/pg-node || return 1
  export SERVICE_PORT=62050 NODE_HOST=127.0.0.1 SERVICE_PROTOCOL=grpc
  export API_KEY="$(cat "$DATA/node_api_key")"
  export SSL_CERT_FILE="$DATA/node-certs/cert.pem" SSL_KEY_FILE="$DATA/node-certs/key.pem"
  exec ./main
}
supervise "core" /run/chost-node.pid node_run &

# ---- panel: database update first (retried until it works), then the panel ----
panel_run() {
  cd /code || return 1
  touch /run/chost-migrating
  until python -m alembic upgrade head; do echo "[chost] database update failed, retrying in 5s"; sleep 5; done
  rm -f /run/chost-migrating
  exec python main.py
}
supervise "panel" /run/chost-panel.pid panel_run &

# ---- auto setup + doctor (finds and fixes problems on its own) ----
supervise "setup" /run/chost-setup.pid bash -c 'cd /code && exec python bootstrap.py' &

# ---- Telegram sales bot (idle until it is turned on in the sidebar page "ربات تلگرام") ----
( sleep 20; supervise "sales bot" /run/chost-bot.pid bash -c 'cd /code && exec python chostbot.py' ) &

supervise "nginx" /run/chost-nginx.pid nginx -g 'daemon off;' &

# ---- watchdog: a part that stops answering is started again on its own; the service keeps running ----
(
  sleep 180; pf=0; nf=0   # slow regions start slower: give them time before watching
  while true; do
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/healthz; then nf=0; else nf=$((nf+1)); fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8000/api/system)
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "403" ]; then pf=0; else pf=$((pf+1)); fi
    if [ "$nf" -ge 3 ]; then echo "[chost] doctor: nginx not answering, starting it again"; kill "$(cat /run/chost-nginx.pid 2>/dev/null)" 2>/dev/null; nf=0; fi
    [ -f /run/chost-migrating ] && pf=0   # never interrupt a database update
    if [ "$pf" -ge 6 ]; then echo "[chost] doctor: panel not answering, starting it again"; kill "$(cat /run/chost-panel.pid 2>/dev/null)" 2>/dev/null; pf=0; fi
    sleep 20
  done
) &

# the container stays up; parts are healed in place
while true; do sleep 3600; done
