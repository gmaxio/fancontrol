#!/bin/zsh
# Remove only the files installed by FanControl. No action is taken unless the
# caller explicitly confirms it with --yes.
set -eu

usage() {
    print "Usage: zsh uninstall.sh --yes [--purge-data]"
    print "  --yes         remove the FanControl app, helper, CLI, and LaunchAgent"
    print "  --purge-data  also remove local presets, preferences, and logs"
}

PURGE_DATA=false
if [[ "${1:-}" != "--yes" ]]; then
    usage
    exit 2
fi
if [[ "${2:-}" == "--purge-data" ]]; then
    PURGE_DATA=true
elif [[ -n "${2:-}" ]]; then
    usage
    exit 2
fi

USER_NAME="$(/usr/bin/id -un)"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
if [[ -z "$USER_HOME" || "$USER_HOME" == "/" ]]; then
    print -u2 "Could not determine the current user's home directory; nothing was removed."
    exit 1
fi

DEST="$USER_HOME/.fancontrol"
CONFIG="$USER_HOME/.config/fancontrol"
AGENT_PLIST="$USER_HOME/Library/LaunchAgents/io.github.gmaxio.fancontrol.cli.plist"
PRIV_SMC="/Library/PrivilegedHelperTools/io.github.gmaxio.fancontrol.smc"
APP="/Applications/FanControl.app"

/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$AGENT_PLIST" 2>/dev/null || true
/bin/rm -f "$AGENT_PLIST" "$DEST/bin/smc"

APP_ID=""
if [[ -f "$APP/Contents/Info.plist" ]]; then
    APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
fi

ADMIN_COMMAND="/bin/rm -f '$PRIV_SMC' '/usr/local/bin/fancontrol'"
if [[ "$APP_ID" == "io.github.gmaxio.fancontrol" ]]; then
    ADMIN_COMMAND="$ADMIN_COMMAND && /bin/rm -rf '$APP'"
elif [[ -d "$APP" ]]; then
    print "Not removing $APP because its bundle identifier does not match FanControl."
fi

if ! /usr/bin/osascript -e "do shell script \"$ADMIN_COMMAND\" with administrator privileges"; then
    print -u2 "Administrator authorization was cancelled or failed. User-level files were left in place."
    exit 1
fi

/bin/rm -rf "$DEST"
if [[ "$PURGE_DATA" == true ]]; then
    /bin/rm -rf "$CONFIG"
    print "Removed FanControl and its local data."
else
    print "Removed FanControl. Local presets, preferences, and logs remain in $CONFIG."
    print "Run again with --yes --purge-data to remove that data."
fi
