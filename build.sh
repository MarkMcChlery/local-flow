#!/bin/bash
# Builds Local Flow into a proper macOS app.
#   ./build.sh            -> builds build/LocalFlow.app
#   ./build.sh --install  -> builds, copies to /Applications, and launches it
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31mERROR: %s\033[0m\n" "$1"; exit 1; }

# ---------- Pre-flight checks ----------
[[ "$(uname -m)" == "arm64" ]] || fail "This app needs an Apple Silicon Mac (M1 or later)."

if ! xcode-select -p &>/dev/null || [[ "$(xcode-select -p)" != *"Xcode.app"* ]]; then
  fail "Full Xcode is required (not just Command Line Tools).
  1. Install Xcode from the App Store (free).
  2. Open it once and let it finish setting up.
  3. Run: sudo xcode-select -s /Applications/Xcode.app
  4. Re-run this script."
fi

bold "Building Local Flow (first build downloads dependencies, takes a few minutes)…"
swift build -c release 2>&1 | tail -5

# ---------- Assemble the .app bundle ----------
APP="build/LocalFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/LocalFlow" "$APP/Contents/MacOS/LocalFlow"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

# Ad-hoc code signature: fine for running on this Mac.
codesign --force --sign - "$APP"

bold "Built: $PWD/$APP"

# ---------- Optional install ----------
if [[ "${1:-}" == "--install" ]]; then
  bold "Installing to /Applications…"
  osascript -e 'quit app "LocalFlow"' 2>/dev/null || true
  rm -rf "/Applications/LocalFlow.app"
  cp -R "$APP" "/Applications/LocalFlow.app"
  open "/Applications/LocalFlow.app"
  bold "Launched. Look for the microphone icon in your menu bar (top right)."
  echo "Reminder: after every rebuild + reinstall, macOS treats it as a new app,"
  echo "so re-tick LocalFlow in System Settings -> Privacy & Security -> Accessibility."
fi
