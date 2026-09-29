#!/usr/bin/env bash
# One-command local setup for JARVIS (https://github.com/ethanplusai/jarvis) + Claude Code integration.
# Usage: bash jarvis-setup.sh [target-dir]        (default: ~/jarvis)  — safe to re-run to upgrade.
# Binds to 127.0.0.1 only. Never expose JARVIS on 0.0.0.0: every run it spawns has full privileges.
set -euo pipefail

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
  rm -f chats_view.py tests/test_chats_view.py tests/test_voice_fallbacks.py \
        frontend/src/chat.ts frontend/src/chat.css frontend/src/hud.ts frontend/src/hud.css \
        frontend/src/chats.ts frontend/src/chats.css
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

# Background launcher, used by the /jarvis command inside Claude Code.
cat > start-jarvis.sh <<'LAUNCH'
#!/usr/bin/env bash
cd "$(dirname "$0")"
# shellcheck disable=SC1091
if [ -f .venv/bin/activate ]; then . .venv/bin/activate; elif [ -f .venv/Scripts/activate ]; then . .venv/Scripts/activate; fi
mkdir -p logs
if curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1; then
  echo "JARVIS ya está en marcha."
else
  nohup python server.py --host 127.0.0.1 > logs/server.log 2>&1 &
  (cd frontend && nohup npm run dev > ../logs/frontend.log 2>&1 &)
  for _ in $(seq 1 60); do curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1 && break; sleep 1; done
  if ! curl -fs http://127.0.0.1:8340/api/runs >/dev/null 2>&1; then
    echo "ERROR: el servidor de JARVIS no arrancó. Últimas líneas de logs/server.log:" >&2
    tail -n 40 logs/server.log >&2
    exit 1
  fi
fi
echo "JARVIS: http://localhost:5173   (Ctrl+K = todas tus conversaciones)"
{ start http://localhost:5173 || open http://localhost:5173 || xdg-open http://localhost:5173; } >/dev/null 2>&1 || true
LAUNCH
chmod +x start-jarvis.sh

# /jarvis slash command for Claude Code (user scope): starts JARVIS and opens its UI.
mkdir -p "$HOME/.claude/commands"
cat > "$HOME/.claude/commands/jarvis.md" <<CMD
---
description: Inicia JARVIS y abre su interfaz (chat, voz y todas tus conversaciones)
---
Ejecuta \`bash "$DIR/start-jarvis.sh"\` y confírmame cuando esté listo.
Después dime que abra http://localhost:5173 en Google Chrome: ahí puede hablar o escribir a JARVIS,
y con Ctrl+K ve todas sus conversaciones de Claude Code, actualizadas en directo.
CMD

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
