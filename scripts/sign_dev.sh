#!/bin/zsh
# sign_dev.sh — build Reel and re-sign it with the pinned dev cert so the
# TCC identity (Screen Recording / Accessibility grants) stops churning.
#
# Why: macOS ties permission grants to the app's code-signing identity.
# Xcode's automatic signing can pick either of the two dev certs on this
# Mac, which invalidates the grant on every rebuild. Pinning one cert
# (850BD1…, team KX4SBPJ7C4) keeps the grant stable across builds.
#
# Usage: scripts/sign_dev.sh [Debug|Release]   (default: Debug)

set -euo pipefail

CERT_HASH="850BD19BB5975887A189E3EAEE256FE4CACFA93B"
CONFIG="${1:-Debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"

echo "▸ Building Reel ($CONFIG)…"
xcodebuild -project "$ROOT/Reel.xcodeproj" \
  -scheme Reel \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build | tail -3

APP="$DERIVED/Build/Products/$CONFIG/Reel.app"
[[ -d "$APP" ]] || { echo "✗ Build product not found at $APP" >&2; exit 1; }

echo "▸ Re-signing with pinned cert $CERT_HASH…"
codesign --force --deep --sign "$CERT_HASH" "$APP"

echo "▸ Verifying signature…"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true

echo "✓ Signed app: $APP"
echo "  (Grant Screen Recording + Accessibility to THIS binary once;"
echo "   future builds signed by this script keep the grant.)"
