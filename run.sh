#!/usr/bin/env bash
# Launch the FloatingSub overlay from WSL.
#
#   ./run.sh              start the overlay (Ctrl+C or close the window to stop)
#   ./run.sh --selftest   check SMTC + lyrics wrking, print the result, exit
#   ./run.sh --stop       kill a running overlay
#   ./run.sh --logs       tail the app log
#
# The script is synced to %LOCALAPPDATA%\SpotifyFloatingSub and executed there,
# because PowerShell cannot reliably load a script straight off \\wsl.localhost.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v cmd.exe >/dev/null 2>&1 || die "cmd.exe not found - this must run under WSL with Windows interop enabled."

WIN_LOCALAPPDATA="$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n')"
[[ -n "$WIN_LOCALAPPDATA" ]] || die "could not read %LOCALAPPDATA% from Windows."

WIN_DEST="${WIN_LOCALAPPDATA}\\SpotifyFloatingSub"
UNIX_DEST="$(wslpath -u "$WIN_DEST")"

case "${1:-}" in
  --stop)
    powershell.exe -NoProfile -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" |
         Where-Object { \$_.CommandLine -like '*FloatingSub.ps1*' } |
         ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1 || true
    echo "stopped any running overlay."
    exit 0
    ;;
  --logs)
    exec tail -n 60 -f "$UNIX_DEST/floatsub.log"
    ;;
esac

mkdir -p "$UNIX_DEST"
cp -f "$SRC"/*.ps1 "$UNIX_DEST"/

ARGS=()
case "${1:-}" in
  --selftest) ARGS+=('-SelfTest') ;;
esac

exec powershell.exe -NoProfile -STA -File "${WIN_DEST}\\FloatingSub.ps1" "${ARGS[@]+"${ARGS[@]}"}"
