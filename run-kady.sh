#!/usr/bin/env bash
#
# run-kady.sh — single entry point to launch K-Dense BYOK (Kady) behind an
# ngrok tunnel with HTTP basic auth.
#
# What it does:
#   1. Starts (or reuses) an ngrok tunnel to the Kady UI port.
#   2. Detects the tunnel's public hostname from the ngrok local API.
#   3. Wires that hostname into ALLOWED_DEV_ORIGINS so Next.js dev mode will
#      serve its HMR/_next resources to the tunnel (otherwise the UI hangs on
#      "Loading project").
#   4. Starts the Kady stack (frontend :3000 + backend :8000).
#   5. Verifies local services and the public URL (expects 401 without creds,
#      200 with creds).
#
# Usage:
#   ./run-kady.sh            Start everything and report the public URL.
#   ./run-kady.sh --status   Show current tunnel + service status, then exit.
#   ./run-kady.sh --stop     Stop Kady and the ngrok tunnel.
#
# Env overrides (optional):
#   KADY_PORT          UI port (default 3000)
#   BACKEND_PORT       backend port (default 8000)
#   NGROK_API          ngrok inspector API (default http://localhost:4040)
#   BASIC_AUTH_USER    basic-auth username (default kady)
#   PW_FILE            file holding the basic-auth password
#                      (default ~/.kady_ngrok_pw; auto-generated if missing)

set -euo pipefail

# --- resolve paths relative to this script ---------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KADY_PORT="${KADY_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
NGROK_API="${NGROK_API:-http://localhost:4040}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-kady}"
PW_FILE="${PW_FILE:-$HOME/.kady_ngrok_pw}"

KADY_LOG="$SCRIPT_DIR/kady-start.log"
NGROK_LOG="$SCRIPT_DIR/ngrok.log"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
info()  { echo "${c_bld}•${c_rst} $*"; }
ok()    { echo "${c_grn}✓${c_rst} $*"; }
warn()  { echo "${c_ylw}!${c_rst} $*"; }
err()   { echo "${c_red}✗${c_rst} $*" >&2; }

# --- helpers ---------------------------------------------------------------

# Read the first https public hostname (no scheme) from the ngrok local API.
# Must never return non-zero: it is called inside a retry loop under
# `set -e -o pipefail`, where a not-yet-ready API would otherwise abort the
# whole script on the first attempt.
tunnel_host() {
  local json host
  json="$(curl -s --max-time 3 "$NGROK_API/api/tunnels" 2>/dev/null || true)"
  host="$(printf '%s' "$json" \
    | jq -r '.tunnels[]? | select(.proto=="https") | .public_url' 2>/dev/null \
    | head -n1 | sed -E 's#^https?://##' 2>/dev/null || true)"
  printf '%s' "$host"
  return 0
}

ngrok_running()  { pgrep -x ngrok >/dev/null 2>&1; }
kady_running()   { pgrep -f "tsx src/index.ts" >/dev/null 2>&1 || pgrep -f "next dev -p" >/dev/null 2>&1; }

http_code() { curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$@" 2>/dev/null || echo "000"; }

ensure_password() {
  if [[ ! -s "$PW_FILE" ]]; then
    info "No basic-auth password found — generating one at $PW_FILE"
    openssl rand -base64 18 | tr -d '/+=' | cut -c1-20 > "$PW_FILE"
    chmod 600 "$PW_FILE"
  fi
  BASIC_AUTH_PW="$(cat "$PW_FILE")"
}

# --- subcommands -----------------------------------------------------------

# Kill processes matching a pattern WITHOUT killing this script, its parent,
# or its own process group. pkill -f matches full command lines (which can
# include our own wrapper shell), so we filter explicitly. Optional 2nd arg
# is the signal (default TERM).
safe_kill() {
  local pattern="$1" sig="${2:-TERM}" self=$$ ppid=$PPID pgid
  pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  local pids pid pg
  pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
  for pid in $pids; do
    [[ "$pid" == "$self" || "$pid" == "$ppid" ]] && continue
    pg="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -n "$pgid" && "$pg" == "$pgid" ]] && continue   # never touch our own group
    kill "-$sig" "$pid" 2>/dev/null || true
  done
}

# True while any Kady supervisor/child is alive (excludes our own group).
supervisor_alive() { pgrep -f "node start.mjs" >/dev/null 2>&1; }

do_stop() {
  info "Stopping Kady and ngrok..."
  # The launcher (start.mjs) is a supervisor that respawns child services when
  # they die. Kill the supervisor FIRST and wait until it is actually gone,
  # otherwise it immediately relaunches the children we just killed.
  safe_kill "node start.mjs"
  safe_kill "start.sh"
  for i in $(seq 1 10); do supervisor_alive || break; sleep 1; done
  if supervisor_alive; then
    warn "Supervisor still alive — escalating to SIGKILL."
    safe_kill "node start.mjs" KILL
    safe_kill "start.sh" KILL
    sleep 2
  fi
  # Now the children won't be respawned; clean up any stragglers.
  safe_kill "tsx src/index.ts"
  safe_kill "next dev -p"
  sleep 1
  safe_kill "tsx src/index.ts" KILL
  safe_kill "next dev -p" KILL
  pkill -x ngrok 2>/dev/null || true
  sleep 2
  if kady_running || ngrok_running || supervisor_alive; then
    warn "Some processes may still be shutting down. Re-run '--status' to confirm."
  else
    ok "All stopped."
  fi
}

do_status() {
  local host code
  if ngrok_running; then
    host="$(tunnel_host)"
    [[ -n "$host" ]] && ok "ngrok tunnel: https://$host" || warn "ngrok running but no https tunnel reported yet"
  else
    warn "ngrok not running"
  fi
  if kady_running; then
    ok "Kady processes running"
  else
    warn "Kady not running"
  fi
  code="$(http_code "http://localhost:$KADY_PORT")";            echo "  local  :$KADY_PORT       -> $code"
  code="$(http_code "http://localhost:$BACKEND_PORT/health")";  echo "  local  :$BACKEND_PORT/health -> $code"
}

# --- main start flow -------------------------------------------------------

do_start() {
  ensure_password

  # 1. ngrok tunnel ---------------------------------------------------------
  if ngrok_running && [[ -n "$(tunnel_host)" ]]; then
    ok "Reusing existing ngrok tunnel."
  else
    info "Starting ngrok tunnel to :$KADY_PORT (basic auth as '$BASIC_AUTH_USER')..."
    nohup ngrok http "$KADY_PORT" \
      --basic-auth "${BASIC_AUTH_USER}:${BASIC_AUTH_PW}" \
      --log=stdout > "$NGROK_LOG" 2>&1 &
    disown
  fi

  # 2. detect hostname ------------------------------------------------------
  info "Waiting for the ngrok hostname..."
  HOST=""
  for i in $(seq 1 30); do
    HOST="$(tunnel_host)"
    [[ -n "$HOST" ]] && break
    sleep 1
  done
  if [[ -z "$HOST" ]]; then
    err "Could not determine ngrok hostname from $NGROK_API/api/tunnels."
    err "Check $NGROK_LOG (is the authtoken configured? 'ngrok config add-authtoken <TOKEN>')."
    exit 1
  fi
  ok "Tunnel hostname: $HOST"
  export ALLOWED_DEV_ORIGINS="$HOST"

  # 3. start exactly one Kady stack ---------------------------------------
  # Always clear any existing/mid-shutdown Kady processes first, then wait
  # until they are actually gone. This avoids process pileup from a stale
  # "already running" state and guarantees the new ALLOWED_DEV_ORIGINS applies.
  if kady_running || supervisor_alive; then
    warn "Clearing existing Kady processes before (re)start..."
    # Reuse the supervisor-aware teardown, but keep the ngrok tunnel we just
    # confirmed. Kill supervisor first, wait, then children (with escalation).
    safe_kill "node start.mjs"
    safe_kill "start.sh"
    for i in $(seq 1 10); do supervisor_alive || break; sleep 1; done
    safe_kill "node start.mjs" KILL
    safe_kill "start.sh" KILL
    safe_kill "tsx src/index.ts"
    safe_kill "next dev -p"
    sleep 1
    safe_kill "tsx src/index.ts" KILL
    safe_kill "next dev -p" KILL
  fi
  for i in $(seq 1 15); do
    { kady_running || supervisor_alive; } || break
    sleep 1
  done
  if kady_running || supervisor_alive; then
    err "Existing Kady processes did not exit; aborting to avoid duplicates."
    err "Run '$0 --stop' and try again."
    exit 1
  fi
  info "Starting Kady stack (ALLOWED_DEV_ORIGINS=$HOST)..."
  # Point the browser bundle at a same-origin proxy path on the tunnel; Next
  # rewrites it to the local backend (see web/next.config.ts). This is what
  # makes the UI's API/SSE calls work through ngrok instead of hitting the
  # viewer's own localhost:8000.
  local api_url="https://$HOST/kady-api"
  ALLOWED_DEV_ORIGINS="$HOST" NEXT_PUBLIC_ADK_API_URL="$api_url" \
    setsid bash -c "./start.sh > '$KADY_LOG' 2>&1" < /dev/null &
  disown

  # 4. wait for services ----------------------------------------------------
  info "Waiting for Kady services to come up (first start can take a minute)..."
  local up=0
  for i in $(seq 1 90); do
    if [[ "$(http_code "http://localhost:$KADY_PORT")" == "200" ]] \
       && [[ "$(http_code "http://localhost:$BACKEND_PORT/health")" == "200" ]]; then
      up=1; break
    fi
    sleep 2
  done
  if [[ "$up" != "1" ]]; then
    err "Services did not become healthy in time. See $KADY_LOG."
    exit 1
  fi
  ok "Local services healthy (:$KADY_PORT and :$BACKEND_PORT)."

  # 5. verify public URL + auth --------------------------------------------
  local url="https://$HOST"
  local no_creds with_creds
  no_creds="$(http_code -H 'ngrok-skip-browser-warning: 1' "$url")"
  with_creds="$(http_code -H 'ngrok-skip-browser-warning: 1' -u "${BASIC_AUTH_USER}:${BASIC_AUTH_PW}" "$url")"
  if [[ "$no_creds" == "401" && "$with_creds" == "200" ]]; then
    ok "Public URL reachable and protected (401 without creds, 200 with)."
  else
    warn "Unexpected public checks: no-creds=$no_creds, with-creds=$with_creds (expected 401 then 200)."
  fi

  # 6. summary --------------------------------------------------------------
  echo
  echo "============================================"
  echo "  Kady is running"
  echo "============================================"
  echo "  Local UI : http://localhost:$KADY_PORT"
  echo "  Public   : $url"
  echo "  Login    : $BASIC_AUTH_USER / $BASIC_AUTH_PW"
  echo "  Logs     : $KADY_LOG"
  echo "             $NGROK_LOG"
  echo "  Inspector: $NGROK_API"
  echo
  echo "  Stop with: $0 --stop"
  echo "============================================"
}

case "${1:-start}" in
  start|"")  do_start ;;
  --status|status) do_status ;;
  --stop|stop)     do_stop ;;
  -h|--help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) err "Unknown option: $1"; echo "Try: $0 [--status|--stop|--help]"; exit 2 ;;
esac
