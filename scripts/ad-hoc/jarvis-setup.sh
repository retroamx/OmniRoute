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
need node "Necesitas Node.js 18+"
need npm "Viene con Node.js"
need claude "Ejecuta: npm install -g @anthropic-ai/claude-code   y luego 'claude' para iniciar sesión"

# Find a real Python 3.11+ (Windows has no python3 and ships a Microsoft Store stub that is not Python).
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "Falta Python 3.11+ (instálalo desde https://www.python.org/downloads/ marcando 'Add python.exe to PATH' y reabre la terminal)" >&2; exit 1; }
claude auth status >/dev/null 2>&1 || { echo "Inicia sesión primero: ejecuta 'claude'" >&2; exit 1; }

[ -d "$DIR/.git" ] || git clone https://github.com/ethanplusai/jarvis.git "$DIR"
cd "$DIR"

# Offline voice fallback (espeak-ng + ffmpeg) for when there is no FISH_API_KEY.
# Voice chain without FISH_API_KEY: Edge TTS (free neural voice, internet) -> espeak-ng (offline).
if [ -f "$PATCH" ] && ! grep -q synthesize_edge tts.py; then
  git checkout -- tts.py server.py requirements.txt 2>/dev/null || true   # drop an older version of our patch
  git apply "$PATCH" && echo "Voz gratuita (Edge TTS) y respaldo local aplicados."
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

echo
echo "JARVIS listo. Arrancando en http://localhost:5173  (Ctrl+C para parar)"
python server.py --host 127.0.0.1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
cd frontend && npm run dev
