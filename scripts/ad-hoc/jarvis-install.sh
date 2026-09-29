#!/usr/bin/env bash
# One-line JARVIS installer for a new computer (Windows Git Bash, macOS or Linux):
#   curl -fsSL https://raw.githubusercontent.com/retroamx/OmniRoute/claude/jarvis-repo-setup-c4aadv/scripts/ad-hoc/jarvis-install.sh | bash
# Downloads the setup script and the JARVIS improvements into ~/jarvis-setup, installs JARVIS in
# ~/jarvis and starts it. Safe to run again (it upgrades instead of reinstalling).
set -euo pipefail
BASE="https://raw.githubusercontent.com/retroamx/OmniRoute/claude/jarvis-repo-setup-c4aadv/scripts/ad-hoc"
mkdir -p "$HOME/jarvis-setup"
cd "$HOME/jarvis-setup"
echo "Descargando el instalador de JARVIS..."
curl -fsSL -o jarvis-setup.sh "$BASE/jarvis-setup.sh"
curl -fsSL -o jarvis-mods.patch "$BASE/jarvis-mods.patch"
bash -n jarvis-setup.sh
# stdin is the pipe from curl, not the keyboard: give the setup a real terminal if there is one.
if [ -t 1 ] && [ -r /dev/tty ]; then exec bash jarvis-setup.sh < /dev/tty; else exec bash jarvis-setup.sh; fi
