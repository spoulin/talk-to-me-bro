#!/bin/bash
# Builds the app and installs it in /Applications.
# Usage: scripts/install-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release

APP="build/Talk to me Bro.app"
DEST="/Applications/Talk to me Bro.app"
RUN="^$DEST/Contents/MacOS/"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The installed copy is open: quit it (SIGTERM quits like ⌘Q), then reopen it once replaced.
REOPEN=false
if pgrep -qf "$RUN"; then
    REOPEN=true
    pkill -TERM -f "$RUN"
    for _ in {1..50}; do pgrep -qf "$RUN" || break; sleep 0.2; done
    if pgrep -qf "$RUN"; then
        echo "Talk to me Bro didn't quit: quit it, then try again." >&2
        exit 1
    fi
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"

# Both copies have the same bundle identifier: links (browspeaker://, http), "Open With"
# and the share extension go to the installed one, not to the one in build/.
"$LSREGISTER" -u "$APP"
"$LSREGISTER" -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/BrowSpeakerShare.appex"

if $REOPEN; then open "$DEST"; fi
echo "✓ $DEST"
