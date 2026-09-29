#!/usr/bin/env bash
# One-command local setup for JARVIS (https://github.com/ethanplusai/jarvis) + Claude Code integration.
# Usage: bash jarvis-setup.sh [--no-start] [target-dir]   (default: ~/jarvis)  — safe to re-run to upgrade.
#        --no-start: install/upgrade only, do not launch (used by start-jarvis.sh's update check).
# Binds to 127.0.0.1 only. Never expose JARVIS on 0.0.0.0: every run it spawns has full privileges.
set -euo pipefail

NO_START=0
if [ "${1:-}" = "--no-start" ]; then NO_START=1; shift; fi
DIR="${1:-$HOME/jarvis}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/jarvis-mods.patch"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1'. $2" >&2; exit 1; }; }
need git "Instálalo desde https://git-scm.com"
need node "Necesitas Node.js 18+"
need npm "Viene con Node.js"
need claude "Ejecuta: npm install -g @anthropic-ai/claude-code   y luego 'claude' para iniciar sesión"

# Find a real Python 3.11+ (Windows has no python3 and ships a Microsoft Store stub that is not Python).
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "Falta Python 3.11+ (https://www.python.org/downloads/ marcando 'Add python.exe to PATH'; reabre la terminal)" >&2; exit 1; }
claude auth status >/dev/null 2>&1 || { echo "Inicia sesión primero: ejecuta 'claude'" >&2; exit 1; }

[ -d "$DIR/.git" ] || git clone https://github.com/ethanplusai/jarvis.git "$DIR"
cd "$DIR"

# Our modifications: free neural voice (Edge TTS) + offline fallback, live "all conversations" browser,
# typed chat panel, command-centre HUD, voice-reactive orb. A version marker decides whether the copy in
# this folder is current; an older copy of the patch is removed first, so re-running always upgrades.
PATCH_ID="$(git hash-object "$PATCH" 2>/dev/null || true)"
if [ -f "$PATCH" ] && [ "$(cat .jarvis-mods.id 2>/dev/null || true)" != "$PATCH_ID" ]; then
  echo "Aplicando la versión nueva de las mejoras de JARVIS..."
  git checkout -- . 2>/dev/null || true
  # Remove every file an older copy of the patch added. The list comes from the patch itself
  # (its "new file" entries), so it can never fall out of date again.
  awk '/^diff --git /{f=$4; sub(/^b\//,"",f)} /^new file mode/{print f}' "$PATCH" | while IFS= read -r f; do
    [ -n "$f" ] && rm -f -- "$f"
  done
  git apply "$PATCH" || { echo "No se pudo aplicar el parche. Copia lo que sale arriba y envíamelo." >&2; exit 1; }
  echo "$PATCH_ID" > .jarvis-mods.id
  echo "Mejoras aplicadas (versión ${PATCH_ID:0:8})."
else
  echo "Las mejoras de JARVIS ya están al día (versión ${PATCH_ID:0:8})."
fi

[ -f .env ] || cp .env.example .env
"$PY" -m venv .venv 2>/dev/null || true
# shellcheck disable=SC1091
if [ -f .venv/bin/activate ]; then . .venv/bin/activate; elif [ -f .venv/Scripts/activate ]; then . .venv/Scripts/activate; fi
python -m pip install -q -r requirements.txt
python -m playwright install chromium >/dev/null 2>&1 || echo "Aviso: no se pudo instalar chromium de playwright (solo afecta a read_page/look_at_page)."
(cd frontend && npm install --silent)

# The dev proxy expects TLS; the server started with --host 127.0.0.1 speaks plain HTTP.
sed -i.bak 's|https://localhost:8340|http://127.0.0.1:8340|g' frontend/vite.config.ts

# Background launcher, used by the /jarvis command inside Claude Code. On every start it looks for a
# newer version in GitHub and ASKS before installing it (never updates silently).
printf 'SETUP_DIR=%q\n' "$HERE" > start-jarvis.sh.new
cat >> start-jarvis.sh.new <<'LAUNCH'
# Usage: bash start-jarvis.sh [--update | --no-update-check | --stop]
#   --update           install a newer version without asking (for when you already said yes)
#   --no-update-check  skip the check entirely
#   --stop             stop a running JARVIS (server + interface) and exit
UPDATE_BASE="https://raw.githubusercontent.com/retroamx/OmniRoute/claude/jarvis-repo-setup-c4aadv/scripts/ad-hoc"

# PIDs listening on a local TCP port (Windows via netstat, elsewhere lsof/fuser/ss).
port_pids() {
  local port="$1"
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
      netstat -ano 2>/dev/null | tr -d '\r' | awk -v p=":$port" '$1 == "TCP" && $4 == "LISTENING" && substr($2, length($2) - length(p) + 1) == p { print $5 }' | sort -u ;;
    *)
      { lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null \
        || fuser -n tcp "$port" 2>/dev/null \
        || ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2; } | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u ;;
  esac
}

# Stop JARVIS: only the processes serving its two ports (and their children), never other python/node.
stop_jarvis() {
  local port pid stopped=0
  for port in 8340 5173; do
    for pid in $(port_pids "$port"); do
      case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) taskkill //F //T //PID "$pid" >/dev/null 2>&1 && stopped=1 ;;
        *) pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null && stopped=1 ;;
      esac
    done
  done
  for _ in $(seq 1 20); do
    [ -z "$(port_pids 8340)$(port_pids 5173)" ] && break
    sleep 0.5
  done
  if [ "$stopped" = 1 ]; then echo "JARVIS detenido."; else echo "JARVIS no estaba en marcha."; fi
}

check_update() {
  local mode="$1" tmp remote_id local_id answer
  command -v curl >/dev/null 2>&1 || return 0
  tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 20 -o "$tmp/jarvis-mods.patch" "$UPDATE_BASE/jarvis-mods.patch" \
     || ! curl -fsSL --max-time 20 -o "$tmp/jarvis-setup.sh" "$UPDATE_BASE/jarvis-setup.sh"; then
    echo "(No se pudo comprobar si hay actualizaciones: sin conexión con GitHub. Sigo con la versión actual.)"
    rm -rf "$tmp"; return 0
  fi
  remote_id="$(git hash-object "$tmp/jarvis-mods.patch")"
  local_id="$(cat .jarvis-mods.id 2>/dev/null || true)"
  if [ "$remote_id" = "$local_id" ]; then
    echo "JARVIS está al día (versión ${local_id:0:8})."
    rm -rf "$tmp"; return 0
  fi
  if ! bash -n "$tmp/jarvis-setup.sh" 2>/dev/null; then
    echo "(Hay una versión nueva, pero su instalador está dañado. No se actualiza.)"
    rm -rf "$tmp"; return 0
  fi
  echo "Hay una versión nueva de JARVIS: ${remote_id:0:8} (tienes ${local_id:0:8})."
  if [ "$mode" != "update" ]; then
    if [ ! -t 0 ]; then
      echo "UPDATE_AVAILABLE: ejecuta 'bash $PWD/start-jarvis.sh --update' para instalarla."
      rm -rf "$tmp"; return 0
    fi
    read -r -p "¿Actualizar ahora? (s/n) " answer || answer=n
    case "$answer" in s|S|si|SI|sí|Sí|y|Y) ;; *) echo "Sin actualizar."; rm -rf "$tmp"; return 0 ;; esac
  fi
  if curl -fs --max-time 2 http://127.0.0.1:8340/api/runs >/dev/null 2>&1; then
    echo "Cerrando JARVIS para actualizarlo..."
    stop_jarvis
  fi
  echo "Actualizando..."
  mkdir -p "$SETUP_DIR"
  cp "$tmp/jarvis-mods.patch" "$SETUP_DIR/jarvis-mods.patch"
  cp "$tmp/jarvis-setup.sh" "$SETUP_DIR/jarvis-setup.sh"
  rm -rf "$tmp"
  if bash "$SETUP_DIR/jarvis-setup.sh" --no-start "$PWD"; then
    echo "Actualización instalada."
  else
    echo "La actualización falló (arriba está el motivo). Arranco con lo que hay." >&2
  fi
}

open_browser() {
  # Only the opener that belongs to this OS: on Linux `open` is openvt, not a browser launcher.
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*) cmd.exe /c start "" "$1" >/dev/null 2>&1 < /dev/null || true ;;
    darwin*) open "$1" >/dev/null 2>&1 < /dev/null || true ;;
    *) command -v xdg-open >/dev/null 2>&1 && { xdg-open "$1" >/dev/null 2>&1 < /dev/null & } ;;
  esac
  return 0
}

main() {
  cd "$(dirname "$0")" || exit 1
  local mode="ask"
  case "${1:-}" in
    --update) mode="update" ;;
    --no-update-check) mode="skip" ;;
    --stop) stop_jarvis; return 0 ;;
  esac
  [ "$mode" != "skip" ] && check_update "$mode"
  # shellcheck disable=SC1091
  if [ -f .venv/bin/activate ]; then . .venv/bin/activate; elif [ -f .venv/Scripts/activate ]; then . .venv/Scripts/activate; fi
  mkdir -p logs
  if curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1; then
    echo "JARVIS ya está en marcha."
  else
    # Fully detached: every fd redirected, and the frontend subshell execs into npm, so nothing
    # keeps this terminal (or Claude Code's /jarvis) waiting after the launcher returns.
    nohup python server.py --host 127.0.0.1 > logs/server.log 2>&1 < /dev/null &
    ( cd frontend && exec nohup npm run dev > ../logs/frontend.log 2>&1 < /dev/null ) &
    for _ in $(seq 1 60); do curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1 && break; sleep 1; done
    if ! curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1; then
      echo "ERROR: el servidor de JARVIS no arrancó. Últimas líneas de logs/server.log:" >&2
      tail -n 40 logs/server.log >&2
      return 1
    fi
  fi
  echo "JARVIS: http://localhost:5173   (Ctrl+K = todas tus conversaciones)"
  open_browser http://localhost:5173

}
# One line on purpose: the updater rewrites this file, and bash must never read past this point.
main "$@"; exit $?
LAUNCH
mv -f start-jarvis.sh.new start-jarvis.sh
chmod +x start-jarvis.sh

# /jarvis slash command for Claude Code (user scope): starts JARVIS and opens its UI.
mkdir -p "$HOME/.claude/commands"
cat > "$HOME/.claude/commands/jarvis.md" <<CMD
---
description: Inicia JARVIS y abre su interfaz (chat, voz y todas tus conversaciones)
---
Ejecuta \`bash "$DIR/start-jarvis.sh"\` y confírmame cuando esté listo.
Si la salida incluye UPDATE_AVAILABLE, pregúntame si quiero actualizar JARVIS. Solo si respondo que sí,
ejecuta \`bash "$DIR/start-jarvis.sh" --update\` (si JARVIS ya estaba en marcha, dime que lo cierre antes).
Después dime que abra http://localhost:5173 en Google Chrome: ahí puede hablar o escribir a JARVIS,
y con Ctrl+K ve todas sus conversaciones de Claude Code, actualizadas en directo.
CMD

if [ "$NO_START" = 1 ]; then
  echo "JARVIS instalado/actualizado (sin arrancar)."
  exit 0
fi

if curl -fs --max-time 2 http://127.0.0.1:8340/api/runs >/dev/null 2>&1; then
  echo "Hay un JARVIS en marcha: lo cierro para arrancar la versión nueva."
  bash "$DIR/start-jarvis.sh" --stop || true
fi

echo
echo "Arrancando el servidor de JARVIS..."
mkdir -p logs
python server.py --host 127.0.0.1 > logs/server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1 && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
  sleep 1
done
if ! curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1; then
  echo >&2
  echo "ERROR: el servidor de JARVIS no arrancó. Estas son sus últimas líneas (envíaselas a Claude):" >&2
  echo "-----------------------------------------------------------------" >&2
  tail -n 40 logs/server.log >&2
  echo "-----------------------------------------------------------------" >&2
  echo "Registro completo: $DIR/logs/server.log" >&2
  exit 1
fi
echo "JARVIS listo. Abre http://localhost:5173 en Chrome  (Ctrl+C para parar)"
echo "Desde Claude Code también puedes escribir /jarvis para iniciarlo."
cd frontend && npm run dev
