#!/bin/bash
# One-time setup for the ytmusic-player Omarchy plugin.
#
#   ./setup.sh              register the bridge helper with your browser(s) and
#                           print the remaining (manual) steps
#   ./setup.sh --eq         also install the optional bass / mid / treble equalizer
#   ./setup.sh --uninstall  undo everything this script set up
#
# `omarchy plugin add` only copies the plugin; it can't run anything. The widget
# works without this (song, progress, play / pause / skip), but the queue,
# search, library, likes, lyrics, repeat and the rest need the bridge: a small
# Chromium extension on music.youtube.com plus this helper ("native messaging
# host") that passes messages between it and the bar.
set -euo pipefail

PLUGIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_NAME="ytmusic_player.bridge"
EXT_ID="$(tr -d '[:space:]' < "$PLUGIN_DIR/bridge/extension-id.txt")"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ytmusic-player"
EQ_CONF="$CONFIG_HOME/pipewire/filter-chain.conf.d/ytmusic-player-eq.conf"

# Chromium-family browsers and where they look for native messaging hosts.
BROWSER_DIRS=(
  "$CONFIG_HOME/chromium"
  "$CONFIG_HOME/google-chrome"
  "$CONFIG_HOME/BraveSoftware/Brave-Browser"
  "$CONFIG_HOME/vivaldi"
)

say() { printf '%s\n' "$*"; }

uninstall() {
  for dir in "${BROWSER_DIRS[@]}"; do
    rm -f "$dir/NativeMessagingHosts/$HOST_NAME.json"
  done
  if [[ -f $EQ_CONF ]]; then
    "$PLUGIN_DIR/bin/music-eq" off 2>/dev/null || true
    rm -f "$EQ_CONF"
    systemctl --user restart filter-chain.service 2>/dev/null || true
    say "Removed the equalizer (filter-chain.service is left enabled; disable it with"
    say "  systemctl --user disable --now filter-chain.service   if nothing else uses it)."
  fi
  say "Removed the bridge helper registration."
  say "Remove the browser extension yourself in chrome://extensions, and the plugin with:"
  say "  omarchy plugin remove dqckey.ytmusic-player"
  say "Settings / state stay in $CONFIG_HOME/ytmusic-player and $STATE_DIR (delete them if you like)."
}

install_eq() {
  mkdir -p "$(dirname "$EQ_CONF")"
  cp "$PLUGIN_DIR/eq/ytmusic-player-eq.conf" "$EQ_CONF"
  systemctl --user enable filter-chain.service >/dev/null 2>&1 || true
  systemctl --user restart filter-chain.service
  sleep 1
  "$PLUGIN_DIR/bin/music-eq" apply || true
  say "Equalizer installed (starts flat). Bass / mid / treble are in the player's settings gear."
  say "It shows as \"YouTube Music\" in audio settings; everything Chromium plays goes through it."
}

case "${1:-}" in
  --uninstall) uninstall; exit 0 ;;
  --eq|"") ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) say "unknown option: $1 (try --help)"; exit 2 ;;
esac

command -v python3 >/dev/null || { say "python3 is required"; exit 1; }
[[ -n $EXT_ID ]] || { say "bridge/extension-id.txt is missing"; exit 1; }

chmod +x "$PLUGIN_DIR/bin/"* "$PLUGIN_DIR/bridge/host.py"
mkdir -p -m 700 "$STATE_DIR"
chmod 700 "$STATE_DIR"   # song, queue and searches: this user only
mkdir -p "$CONFIG_HOME/ytmusic-player"

registered=0
for dir in "${BROWSER_DIRS[@]}"; do
  [[ -d $dir ]] || continue
  mkdir -p "$dir/NativeMessagingHosts"
  cat > "$dir/NativeMessagingHosts/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "ytmusic-player bar bridge",
  "path": "$PLUGIN_DIR/bridge/host.py",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
  say "Registered the bridge helper for $(basename "$dir")."
  registered=1
done
(( registered )) || say "No Chromium-family browser config found (chromium / google-chrome / brave / vivaldi)."

[[ ${1:-} == --eq ]] && install_eq

cat <<EOF

Next steps (once):
  1. In your browser open chrome://extensions, turn on "Developer mode",
     click "Load unpacked" and choose:
       $PLUGIN_DIR/bridge/extension
  2. Reload your YouTube Music tab / window (F5).

Optional keyboard shortcuts: add these to ~/.config/hypr/bindings.lua
(the hl.unbind lines free keys Omarchy already uses):

  hl.unbind("SUPER + SHIFT + M")      -- was: Spotify
  o.bind("SUPER + SHIFT + M", "Music player", "omarchy-shell shell toggle dqckey.ytmusic-player")
  o.bind("SUPER + CTRL + M", "Play / pause music", "omarchy-shell -q ytmusic-player-media toggle")
  hl.unbind("SUPER + CTRL + RIGHT")   -- was: next window in a group
  hl.unbind("SUPER + CTRL + LEFT")    -- was: previous window in a group
  o.bind("SUPER + CTRL + RIGHT", "Next song", "omarchy-shell -q ytmusic-player-media next")
  o.bind("SUPER + CTRL + LEFT", "Previous song", "omarchy-shell -q ytmusic-player-media previous")
  o.bind("SUPER + CTRL + UP", "Music volume up", "omarchy-shell -q ytmusic-player-volume up", { repeating = true })
  o.bind("SUPER + CTRL + DOWN", "Music volume down", "omarchy-shell -q ytmusic-player-volume down", { repeating = true })

Undo all of this with: $PLUGIN_DIR/setup.sh --uninstall
EOF
