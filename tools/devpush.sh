#!/usr/bin/env bash
# Copy the mod's Lua into the game and (optionally) run one script via VConsole.
# usage: tools/devpush.sh [script_to_run_without_.lua] [extra vcon.py args...]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME="${HLA_DIR:-/d/SteamLibrary/steamapps/common/Half-Life Alyx}"
VS="$GAME/game/hlvr/scripts/vscripts"
mkdir -p "$VS/alyxmp"
cp -r "$ROOT/mod/game/hlvr/scripts/vscripts/alyxmp/." "$VS/alyxmp/"
if [ -n "$1" ]; then
  s="$1"; shift
  python "$ROOT/tools/vcon.py" --wait 3 "$@" "script_reload_code $s"
fi
