#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_NAME="Codex via 9Router"
PORT=$(printenv NINEROUTER_PORT 2>/dev/null || true)
MODEL=$(printenv NINEROUTER_MODEL 2>/dev/null || true)
[ -n "$PORT" ] || PORT=20128
[ -n "$MODEL" ] || MODEL=apmix/deepseek-v4-flash-free
BASE_URL="http://127.0.0.1:$PORT/v1"
DATA_DIR="$HOME/.9router"
DB_FILE="$DATA_DIR/db/data.sqlite"
PID_FILE="$DATA_DIR/codex-launcher-$PORT.pid"
LOG_DIR="$DATA_DIR/logs"
LOG_FILE="$LOG_DIR/codex-launcher-$PORT.log"
MODE=panel

usage() {
  cat <<'EOF'
Codex via local 9Router

Usage:
  codex-9router.sh [prompt ...]   Start 9Router, then run Codex with the prompt
  codex-9router.sh                Open the interactive control panel
  codex-9router.sh --dashboard    Start 9Router and show its dashboard URL
  codex-9router.sh --check        Run a read-only live response check
  codex-9router.sh --stop         Stop the recorded 9Router server after ownership validation
  codex-9router.sh --help         Show this help

Optional environment:
  NINEROUTER_PORT   Local 9Router port (default: 20128)
  NINEROUTER_MODEL  Preselect a model id (default: apmix/deepseek-v4-flash-free)

With prompt arguments, the launcher starts 9Router if needed and runs Codex
directly after the gateway is ready. Without prompt arguments, it opens the
interactive panel, which lists live models, tests a model with a read-only
Codex request, and launches Codex. Manage provider endpoints and provider
credentials in the 9Router dashboard; this launcher does not edit 9Router's
database.

The script reads a local 9Router client key from its database and never stores
provider secrets. Add provider endpoints and credentials in the 9Router dashboard.
EOF
}

fail() {
  printf '%s: %s\n' "$APP_NAME" "$1" >&2
  exit 1
}

is_router_process() {
  local process_pid process_args process_cwd
  process_pid=$1
  kill -0 "$process_pid" 2>/dev/null || return 1
  process_args=$(ps -p "$process_pid" -o args= 2>/dev/null || true)
  case "$process_args" in
    *next-server*)
      process_cwd=$(readlink "/proc/$process_pid/cwd" 2>/dev/null || true)
      case "$process_cwd" in */9router/*) return 0 ;; esac
      ;;
  esac
  case "$process_args" in *9router*) return 0 ;; esac
  return 1
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --check) MODE=check; shift ;;
    --stop) MODE=stop; shift ;;
    --dashboard) MODE=dashboard; shift ;;
  esac
fi

if [ "$MODE" = stop ]; then
  if [ ! -f "$PID_FILE" ]; then
    printf 'No launcher-owned 9Router process recorded for port %s; left other servers running.\n' "$PORT"
    exit 0
  fi
  SERVER_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  case "$SERVER_PID" in
    ''|*[!0-9]*) rm -f "$PID_FILE"; fail "The saved server PID is invalid; removed the stale PID file." ;;
  esac
  if ! is_router_process "$SERVER_PID"; then
    rm -f "$PID_FILE"
    fail "PID $SERVER_PID is not a live 9Router process; removed the stale PID file without stopping it."
  fi
  pkill -P "$SERVER_PID" 2>/dev/null || true
  kill "$SERVER_PID" 2>/dev/null || true
  for ((attempt=0; attempt<5; attempt++)); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 1 || true
  done
  if kill -0 "$SERVER_PID" 2>/dev/null; then kill -9 "$SERVER_PID" 2>/dev/null || true; fi
  rm -f "$PID_FILE"
  printf 'Stopped the 9Router server started by this launcher.\n'
  exit 0
fi

PREFIX_DIR=$(printenv PREFIX 2>/dev/null || true)
PATH="$HOME/.local/bin:$PATH"
if [ -n "$PREFIX_DIR" ]; then PATH="$PREFIX_DIR/bin:$PATH"; fi
export PATH

NODE_BIN=$(command -v node || true)
CURL_BIN=$(command -v curl || true)
CODEX_BIN=$(command -v codex || true)
ROUTER_BIN=$(command -v 9router || true)
[ -n "$ROUTER_BIN" ] || { [ -f "$HOME/.local/lib/node_modules/9router/cli.js" ] && ROUTER_BIN="$HOME/.local/lib/node_modules/9router/cli.js"; }
ROUTER_COMMAND=()
if [ -n "$ROUTER_BIN" ]; then
  case "$ROUTER_BIN" in
    */cli.js) ROUTER_COMMAND=("$NODE_BIN" "$ROUTER_BIN") ;;
    *) ROUTER_COMMAND=("$ROUTER_BIN") ;;
  esac
fi
printf 'Preflight checks\n'
for dependency in bash node curl codex 9router; do
  case "$dependency" in
    bash) dep_path=$(command -v bash || true) ;;
    node) dep_path=$NODE_BIN ;;
    curl) dep_path=$CURL_BIN ;;
    codex) dep_path=$CODEX_BIN ;;
    9router) dep_path=$ROUTER_BIN ;;
  esac
  if [ -n "$dep_path" ]; then printf '  [OK] %-8s %s\n' "$dependency" "$dep_path"; else printf '  [MISSING] %s\n' "$dependency"; fi
done
[ -n "$NODE_BIN" ] || fail "Install Node.js 18 or newer (Termux: pkg install nodejs-lts)."
[ -n "$CURL_BIN" ] || fail "Install curl (Termux: pkg install curl)."
[ -n "$CODEX_BIN" ] || fail "Install and authenticate the Codex CLI, then retry."
[ -n "$ROUTER_BIN" ] || fail "Install 9Router, then retry."
NODE_VERSION=$($NODE_BIN -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf 0)
[[ "$NODE_VERSION" =~ ^[0-9]+$ ]] && [ "$NODE_VERSION" -ge 18 ] || fail "Node.js 18 or newer is required."
CODEX_VERSION=$("$CODEX_BIN" --version 2>&1 | head -n 1 || true)
[ -n "$CODEX_VERSION" ] || fail "Codex CLI is installed but did not return a version. Reinstall or repair the CLI."
printf '  [OK] Codex CLI %s\n' "$CODEX_VERSION"
[ -f "$DB_FILE" ] || fail "9Router data was not found at $DB_FILE. Start and configure 9Router first."

LOCAL_API_KEY=$(NODE_NO_WARNINGS=1 "$NODE_BIN" -e '
try {
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.argv[1], { readOnly: true });
  const row = db.prepare("SELECT key FROM apiKeys WHERE isActive = 1 ORDER BY createdAt ASC LIMIT 1").get();
  if (row && row.key) process.stdout.write(row.key);
  db.close();
} catch (_) { process.exit(1); }
' "$DB_FILE" 2>/dev/null || true)

if [ -z "$LOCAL_API_KEY" ] && command -v python3 >/dev/null 2>&1; then
  LOCAL_API_KEY=$(python3 -c 'import sqlite3,sys; c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True); r=c.execute("SELECT key FROM apiKeys WHERE isActive=1 ORDER BY createdAt ASC LIMIT 1").fetchone(); sys.stdout.write(r[0] if r else "")' "$DB_FILE" 2>/dev/null || true)
fi

gateway_ready() {
  LAST_STATUS=$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/login" 2>/dev/null || true)
  [ -n "$LAST_STATUS" ] || LAST_STATUS=000
  [ "$LAST_STATUS" != 000 ]
}

LAST_STATUS=000

find_server_pid() {
  local candidate_pid candidate_args candidate_cwd candidate_port
  while IFS= read -r candidate_pid; do
    [ -n "$candidate_pid" ] || continue
    candidate_args=$(ps -p "$candidate_pid" -o args= 2>/dev/null || true)
    case "$candidate_args" in *next-server*) ;; *) continue ;; esac
    candidate_cwd=$(readlink "/proc/$candidate_pid/cwd" 2>/dev/null || true)
    case "$candidate_cwd" in */9router/*) ;; *) continue ;; esac
    [ -r "/proc/$candidate_pid/environ" ] || continue
    candidate_port=$(tr '\0' '\n' <"/proc/$candidate_pid/environ" 2>/dev/null | awk -F= '$1 == "PORT" {print substr($0, index($0, "=") + 1); exit}' || true)
    if [ "$candidate_port" = "$PORT" ]; then
      printf '%s\n' "$candidate_pid"
      return 0
    fi
  done < <(ps -eo pid=,args= 2>/dev/null | awk '$0 ~ /next-server/ {print $1}')
  return 1
}

port_is_open() {
  (exec 9<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null
}

stop_unresponsive_router_on_port() {
  local saved_pid attempt
  if port_is_open; then
    saved_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    case "$saved_pid" in ''|*[!0-9]*) saved_pid= ;; esac
    if [ -n "$saved_pid" ] && is_router_process "$saved_pid"; then
      pkill -P "$saved_pid" 2>/dev/null || true
      kill "$saved_pid" 2>/dev/null || true
      for ((attempt=0; attempt<5; attempt++)); do
        kill -0 "$saved_pid" 2>/dev/null || break
        sleep 1 || true
      done
      if kill -0 "$saved_pid" 2>/dev/null; then kill -9 "$saved_pid" 2>/dev/null || true; fi
      rm -f "$PID_FILE"
      return 0
    fi
    printf 'Port %s is accepting TCP connections but not responding to HTTP.\n' "$PORT" >>"$LOG_FILE"
    printf 'Port conflict detected on %s; recent launcher log output follows:\n' "$PORT" >&2
    tail -n 25 "$LOG_FILE" >&2 2>/dev/null || true
    fail "Port $PORT is occupied by another process; left it running. See $LOG_FILE and choose another port with NINEROUTER_PORT."
  fi
}

SERVER_PID=""
if ! gateway_ready; then
  mkdir -p "$LOG_DIR"
  : >"$LOG_FILE"
  stop_unresponsive_router_on_port
  if port_is_open; then
    printf 'Port %s became occupied before 9Router could start.\n' "$PORT" >>"$LOG_FILE"
    printf 'Port conflict detected on %s; recent launcher log output follows:\n' "$PORT" >&2
    tail -n 25 "$LOG_FILE" >&2 2>/dev/null || true
    fail "Port $PORT is occupied by another process; left it running. See $LOG_FILE and choose another port with NINEROUTER_PORT."
  fi
  PREEXISTING_CHILDREN=$(ps -A -o pid= -o args= 2>/dev/null | awk '$2 == "next-server" {print $1}')
  printf 'Starting local 9Router on 127.0.0.1:%s ...\n' "$PORT"
  HOSTNAME=127.0.0.1 nohup "${ROUTER_COMMAND[@]}" --port "$PORT" --host 127.0.0.1 --no-browser --skip-update >>"$LOG_FILE" 2>&1 </dev/null &
  SERVER_PID=$!
  SERVER_IS_CHILD=0
  printf '%s\n' "$SERVER_PID" >"$PID_FILE"
  ready=0
  for ((attempt=1; attempt<=90; attempt++)); do
    if gateway_ready; then ready=1; break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      found_child=0
      while IFS= read -r candidate_pid; do
        [ -n "$candidate_pid" ] || continue
        case " $PREEXISTING_CHILDREN " in *" $candidate_pid "*) continue ;; esac
        SERVER_PID=$candidate_pid
        SERVER_IS_CHILD=1
        found_child=1
        printf '%s\n' "$SERVER_PID" >"$PID_FILE"
        break
      done < <(ps -A -o pid= -o args= 2>/dev/null | awk '$2 == "next-server" {print $1}')
      if [ "$found_child" -eq 0 ]; then
        if [ "$SERVER_IS_CHILD" -eq 1 ]; then break; fi
      fi
    fi
    printf '  waiting %ss (http=%s)\n' "$attempt" "$LAST_STATUS"
    if grep -q 'EADDRINUSE' "$LOG_FILE" 2>/dev/null; then
      rm -f "$PID_FILE"
      tail -n 25 "$LOG_FILE" >&2
      fail "Port $PORT is occupied. The launcher left any process it could not identify as 9Router running; choose another port with NINEROUTER_PORT."
    fi
    [ "$attempt" -eq 90 ] || sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    rm -f "$PID_FILE"
    if [ -f "$LOG_FILE" ]; then tail -n 25 "$LOG_FILE" >&2; fi
    if grep -q 'EADDRINUSE' "$LOG_FILE" 2>/dev/null; then
      fail "Port $PORT is already occupied, but its process could not be identified as an unresponsive 9Router. Check the server and logs at $LOG_FILE, or choose another port with NINEROUTER_PORT."
    fi
    fail "9Router did not start. See $LOG_FILE for details."
  fi
  if [ -f "$PID_FILE" ] && [ "$SERVER_IS_CHILD" -eq 0 ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    while IFS= read -r candidate_pid; do
      [ -n "$candidate_pid" ] || continue
      case " $PREEXISTING_CHILDREN " in *" $candidate_pid "*) continue ;; esac
      SERVER_PID=$candidate_pid
      printf '%s\n' "$SERVER_PID" >"$PID_FILE"
      break
    done < <(ps -A -o pid= -o args= 2>/dev/null | awk '$2 == "next-server" {print $1}')
  fi
  LISTENERS=""
  if command -v netstat >/dev/null 2>&1; then
    LISTENERS=$(netstat -ltn 2>/dev/null | awk -v suffix=":$PORT" '$4 ~ (suffix "$") { print $4 }' || true)
  fi
  if [ -z "$LISTENERS" ]; then
    PORT_HEX=$(printf '%04X' "$PORT")
    LISTENERS=$(awk -v port="$PORT_HEX" '$2 ~ (":" port "$") && $4 == "0A" {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null || true)
  fi
  case "$LISTENERS" in
    *0.0.0.0:*|*:::*|00000000:*|00000000000000000000000000000000:*) printf 'Warning: 9Router is listening on a non-loopback address (%s).\n' "$LISTENERS" >&2 ;;
  esac
else
  printf 'Using running 9Router on 127.0.0.1:%s\n' "$PORT"
  SERVER_PID=$(cat "$PID_FILE" 2>/dev/null || true)
fi

ACTUAL_SERVER_PID=$(find_server_pid || true)
if [ -n "$ACTUAL_SERVER_PID" ]; then
  SERVER_PID=$ACTUAL_SERVER_PID
  printf '%s\n' "$SERVER_PID" >"$PID_FILE"
else
  printf 'Warning: could not identify the 9Router server PID; keeping the existing PID.\n' >&2
fi

if [ "$MODE" = dashboard ]; then
  DASHBOARD_URL="http://127.0.0.1:$PORT/dashboard"
  printf '9Router dashboard: %s\n' "$DASHBOARD_URL"
  printf 'Use Providers to add/edit upstream endpoints and provider API keys. Use API Keys to manage client keys.\n'
  if command -v termux-open-url >/dev/null 2>&1; then termux-open-url "$DASHBOARD_URL" >/dev/null 2>&1 || true; fi
  exit 0
fi

[ -n "$LOCAL_API_KEY" ] || fail "No active 9Router client API key was found. Open the dashboard and create one under API Keys."

printf 'Checking the configured model through local 9Router ...\n'
MODEL_LIST=$({ "$CURL_BIN" -fsS --max-time 20 -H "Authorization: Bearer $LOCAL_API_KEY" "$BASE_URL/models" || exit 1; } | \
  "$NODE_BIN" -e '
let body = "";
process.stdin.on("data", chunk => body += chunk);
process.stdin.on("end", () => {
  try {
    const ids = (JSON.parse(body).data || []).map(item => item.id);
    for (const id of ids) if (typeof id === "string") console.log(id);
  } catch (_) { process.exit(1); }
})' 2>/dev/null) || fail "Could not load models from 9Router. Check the local server and its active provider."

if [ -t 0 ] && [ "$#" -eq 0 ]; then
  mapfile -t MODEL_OPTIONS < <(printf '%s\n' "$MODEL_LIST" | sed '/^$/d' | sort -u)
  if [ "${#MODEL_OPTIONS[@]}" -gt 0 ]; then
    printf '\nModels available from 9Router:\n'
    for i in "${!MODEL_OPTIONS[@]}"; do
      marker=' '
      [ "${MODEL_OPTIONS[$i]}" = "$MODEL" ] && marker='*'
      printf '  %2d)%s %s\n' "$((i + 1))" "$marker" "${MODEL_OPTIONS[$i]}"
    done
    printf 'Select model number (Enter keeps %s): ' "$MODEL"
    IFS= read -r choice || fail "Could not read model selection."
    if [ -n "$choice" ]; then
      [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MODEL_OPTIONS[@]}" ] || fail "Invalid model selection."
      MODEL=${MODEL_OPTIONS[$((choice - 1))]}
    fi
  fi
else
  case $'\n'"$MODEL_LIST"$'\n' in *$'\n'"$MODEL"$'\n'*) ;; *) fail "Model $MODEL is not available from 9Router. Run interactively to choose or add a model ID." ;; esac
fi

case $'\n'"$MODEL_LIST"$'\n' in *$'\n'"$MODEL"$'\n'*) printf 'Selected model: %s\n' "$MODEL" ;; *) fail "The selected model is not available from 9Router." ;; esac

export OPENAI_API_KEY="$LOCAL_API_KEY"
unset LOCAL_API_KEY

CODEX_ARGS=(
  --model "$MODEL"
  -c 'model_provider="apmix_router"'
  -c 'model_providers.apmix_router.name="APmix via 9Router"'
  -c "model_providers.apmix_router.base_url=\"$BASE_URL\""
  -c 'model_providers.apmix_router.env_key="OPENAI_API_KEY"'
  -c 'model_providers.apmix_router.wire_api="responses"'
)

if [ "$MODE" = check ]; then
  [ "$#" -eq 0 ] || fail "--check does not accept a prompt."
  exec "$CODEX_BIN" exec --skip-git-repo-check --ephemeral --sandbox read-only "${CODEX_ARGS[@]}" \
    'Reply with exactly OK and no other text.'
fi

if [ -t 0 ] && [ "$#" -eq 0 ]; then
  while :; do
    printf '\n9Router Control Panel\n'
    printf '  Model: %s\n' "$MODEL"
    printf '  Endpoint: %s\n' "$BASE_URL"
    printf '  1) Launch Codex\n  2) Test selected model\n  3) Manage endpoints and API keys (9Router dashboard)\n  4) Choose another model\n  5) Quit\n'
    printf 'Choose [1-5]: '
    IFS= read -r action || exit 0
    case "$action" in
      1) break ;;
      2)
        printf 'Testing %s with a read-only Codex request ...\n' "$MODEL"
        if "$CODEX_BIN" exec --skip-git-repo-check --ephemeral --sandbox read-only "${CODEX_ARGS[@]}" 'Reply with exactly OK and no other text.'; then
          printf 'Model test succeeded.\n'
        else
          printf 'Model test failed. Review the endpoint, provider credentials, model access, and 9Router logs.\n'
        fi
        ;;
      3)
        printf 'Manage upstream endpoints and their API keys in 9Router Providers; manage Codex client keys in API Keys.\n'
        printf 'Dashboard: http://127.0.0.1:%s/dashboard\n' "$PORT"
        if command -v termux-open-url >/dev/null 2>&1; then termux-open-url "http://127.0.0.1:$PORT/dashboard" >/dev/null 2>&1 || true; fi
        printf 'Press Enter to return to the panel. '
        IFS= read -r _ || true
        printf 'New providers/models will appear after restarting this launcher.\n'
        ;;
      4)
        printf '\nAvailable models:\n'
        mapfile -t MODEL_OPTIONS < <(printf '%s\n' "$MODEL_LIST" | sed '/^$/d' | sort -u)
        for i in "${!MODEL_OPTIONS[@]}"; do printf '  %2d) %s\n' "$((i + 1))" "${MODEL_OPTIONS[$i]}"; done
        printf 'Model number: '
        IFS= read -r choice || exit 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MODEL_OPTIONS[@]}" ]; then
          MODEL=${MODEL_OPTIONS[$((choice - 1))]}
          CODEX_ARGS[1]="$MODEL"
        else
          printf 'Invalid model selection.\n'
        fi
        ;;
      5) exit 0 ;;
      *) printf 'Choose 1 through 5.\n' ;;
    esac
  done
fi

printf 'Launching Codex with %s through 9Router.\n' "$MODEL"
exec "$CODEX_BIN" "${CODEX_ARGS[@]}" "$@"
