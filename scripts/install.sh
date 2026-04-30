#!/bin/bash
# MeetingPilot Installer Script
# Usage: curl -sL <url>/install.sh | bash
#   or:  bash install.sh MeetingPilot-macos15.zip
set -e

APP="MeetingPilot"
BUNDLE_ID="com.hwang.meetingpilot"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP.app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════╗"
echo "║    MeetingPilot Installer            ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Detect macOS version
MACOS_VER=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d. -f1)
info "Detected macOS $MACOS_VER"

# Locate MeetingPilot.app — either next to script or find zip to extract
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/$APP.app"

if [ ! -d "$SOURCE_APP" ]; then
    # Look for zip file next to script or passed as argument
    ZIP_FILE=""
    if [ -n "$1" ] && [ -f "$1" ]; then
        ZIP_FILE="$1"
    else
        ZIP_FILE=$(find "$SCRIPT_DIR" -maxdepth 1 -name "$APP*.zip" | head -1)
        [ -z "$ZIP_FILE" ] && ZIP_FILE=$(find "$(pwd)" -maxdepth 1 -name "$APP*.zip" | head -1)
    fi

    if [ -n "$ZIP_FILE" ] && [ -f "$ZIP_FILE" ]; then
        info "Extracting $ZIP_FILE ..."
        unzip -qo "$ZIP_FILE" -d "$SCRIPT_DIR"
        SOURCE_APP=$(find "$SCRIPT_DIR" -name "$APP.app" -maxdepth 2 -type d | head -1)
    fi

    if [ ! -d "$SOURCE_APP" ]; then
        fail "$APP.app not found. Place this script next to $APP.app or a $APP*.zip file."
    fi
fi

# Stop existing instance
if pgrep -x "$APP" >/dev/null 2>&1; then
    info "Stopping running $APP..."
    killall "$APP" 2>/dev/null || true
    sleep 1
fi

# Remove old installation
if [ -d "$APP_PATH" ]; then
    info "Removing old installation..."
    rm -rf "$APP_PATH"
fi

# Install
info "Installing to $INSTALL_DIR..."
cp -R "$SOURCE_APP" "$APP_PATH"

# Clear quarantine
info "Clearing quarantine attributes..."
xattr -cr "$APP_PATH"

# Reset TCC permissions for clean slate
info "Resetting permissions for clean authorization..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true

# Clear icon cache
touch "$APP_PATH"
killall Dock 2>/dev/null || true

ok "Installed to $APP_PATH"
echo ""

# macOS version specific notes
if [ "$MACOS_MAJOR" -ge 15 ]; then
    warn "macOS 15 requires manual permission grants:"
    echo "  After launching, grant these in System Settings:"
    echo "    • Privacy & Security → Screen Recording → enable $APP"
    echo "    • Privacy & Security → Microphone → enable $APP"
    echo ""
    echo "  If Screen Recording doesn't stick:"
    echo "    1. Remove $APP from the list (-)"
    echo "    2. Re-add it (+) pointing to $APP_PATH"
    echo "    3. Quit and reopen the app"
    echo ""
fi

# Launch
info "Launching $APP..."
open "$APP_PATH"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Installation complete!              ║"
echo "║                                      ║"
echo "║  Grant permissions when prompted.    ║"
echo "║  If Screen Recording fails, quit     ║"
echo "║  and reopen after granting.          ║"
echo "╚══════════════════════════════════════╝"
echo ""
