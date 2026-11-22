#!/bin/bash
# Search selbst bauen und als normale App installieren.
#
#   ./install.sh            bauen (Release) und nach /Applications kopieren
#   ./install.sh --no-build die schon gebaute build/Search.app nur kopieren
#
# Danach liegt Search in /Programme wie jede andere App: Spotlight, Dock,
# als Standardbrowser wählbar (Systemeinstellungen › Desktop & Dock).
# Zum Aktualisieren einfach nach einem `git pull` erneut ausführen; deine
# Tabs, Verlauf und Passwörter bleiben, sie liegen nicht in der App.
set -euo pipefail
cd "$(dirname "$0")"

[ "${1:-}" = "--no-build" ] || ./build.sh release

APP="build/Search.app"
DEST="/Applications/Search.app"
[ -d "$APP" ] || { echo "$APP fehlt – erst ./build.sh release" >&2; exit 1; }

# Läuft Search gerade, sauber beenden, damit die Dateien ersetzt werden können.
if pgrep -x Search >/dev/null; then
  osascript -e 'tell application "Search" to quit' 2>/dev/null || true
  for _ in {1..20}; do pgrep -x Search >/dev/null || break; sleep 0.5; done
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
# Selbst gebaut heißt: nicht aus dem Internet geladen, also keine Quarantäne.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "installiert: $DEST"
open "$DEST"
