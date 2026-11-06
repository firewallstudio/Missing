#!/bin/bash
# Install the latest Missing release from GitHub (no build needed):
#   curl -fsSL https://raw.githubusercontent.com/firewallstudio/Missing/main/install.sh | bash
set -euo pipefail
REPO="firewallstudio/Missing"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▶ Downloading the latest version..."
curl -fsSL "https://github.com/$REPO/releases/latest/download/Missing.zip" -o "$TMP/Missing.zip"
ditto -x -k "$TMP/Missing.zip" "$TMP"

# Only install a package signed with the Missing release certificate (signing/AudioTab.pem)
REQ='identifier "com.firewallstudio.audiotab" and certificate leaf = H"1393C015627262B00A7AABAF54ECDF0AF9C39BAD"'
if ! codesign --verify --deep --strict -R "=$REQ" "$TMP/Missing.app" 2>/dev/null; then
  echo "✖ The download isn't signed with the Missing certificate. Nothing was installed." >&2
  exit 1
fi

for app in GlassTab AudioHop AudioTab Missing; do pkill -x "$app" 2>/dev/null || true; done
sleep 0.5
rm -rf /Applications/AudioTab.app /Applications/Missing.app
ditto "$TMP/Missing.app" /Applications/Missing.app
xattr -dr com.apple.quarantine /Applications/Missing.app 2>/dev/null || true
open /Applications/Missing.app

echo "✅ Missing is installed. Future versions update from inside the app."
