#!/usr/bin/env bash
# One-command local setup + launcher for JARVIS (https://github.com/ethanplusai/jarvis).
# Usage: bash scripts/ad-hoc/jarvis-setup.sh [target-dir]   (default: ~/jarvis)
# Binds to 127.0.0.1 only. Never expose JARVIS on 0.0.0.0: every run it spawns has full privileges.
set -euo pipefail

DIR="${1:-$HOME/jarvis}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/jarvis-local-tts-fallback.patch"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1'. $2" >&2; exit 1; }; }
need git "Instálalo desde https://git-scm.com"
need python3 "Necesitas Python 3.11+"
need node "Necesitas Node.js 18+"
need npm "Viene con Node.js"
need claude "Ejecuta: npm install -g @anthropic-ai/claude-code   y luego 'claude' para iniciar sesión"

python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' || { echo "Python 3.11+ requerido" >&2; exit 1; }
claude auth status >/dev/null 2>&1 || { echo "Inicia sesión primero: ejecuta 'claude'" >&2; exit 1; }

[ -d "$DIR/.git" ] || git clone https://github.com/ethanplusai/jarvis.git "$DIR"
cd "$DIR"

# Offline voice fallback (espeak-ng + ffmpeg) for when there is no FISH_API_KEY.
if [ -f "$PATCH" ] && ! grep -q synthesize_local tts.py; then
  git apply "$PATCH" && echo "Voz local de respaldo aplicada."
fi
command -v espeak-ng >/dev/null && command -v ffmpeg >/dev/null \
  || echo "Aviso: instala espeak-ng y ffmpeg para la voz local de respaldo (sin FISH_API_KEY)."

[ -f .env ] || cp .env.example .env
python3 -m venv .venv 2>/dev/null || true
# shellcheck disable=SC1091
[ -f .venv/bin/activate ] && . .venv/bin/activate
pip install -q -r requirements.txt
python -m playwright install chromium >/dev/null 2>&1 || echo "Aviso: no se pudo instalar chromium de playwright (solo afecta a read_page/look_at_page)."
(cd frontend && npm install --silent)

# The dev proxy expects TLS; the server started with --host 127.0.0.1 speaks plain HTTP.
sed -i.bak 's|https://localhost:8340|http://127.0.0.1:8340|g' frontend/vite.config.ts

echo
echo "JARVIS listo. Arrancando en http://localhost:5173  (Ctrl+C para parar)"
python server.py --host 127.0.0.1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
cd frontend && npm run dev
