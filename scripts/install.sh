#!/bin/bash
# Scripta Installer Script
# Usage: curl -sL <url>/install.sh | bash
#   or:  bash install.sh Scripta-macos15.zip
set -e

APP="Scripta"
BUNDLE_ID="com.thehwang.scripta"
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
echo "║    Scripta Installer            ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Detect macOS version
MACOS_VER=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d. -f1)
info "Detected macOS $MACOS_VER"

# Locate Scripta.app — either next to script or find zip to extract
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

# ── Ollama (AI Summary) ──────────────────────────────────────────────

DEFAULT_MODEL="qwen2.5:3b"

install_ollama() {
    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama already installed ($(ollama --version 2>/dev/null || echo 'unknown version'))"
    else
        info "Installing Ollama for AI meeting summaries..."
        if command -v brew >/dev/null 2>&1; then
            brew install ollama
        else
            info "Homebrew not found, installing Homebrew first..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
            brew install ollama
        fi

        if command -v ollama >/dev/null 2>&1; then
            ok "Ollama installed successfully"
        else
            warn "Ollama installation failed. You can install manually later:"
            echo "  brew install ollama"
            echo "  brew services start ollama"
            echo "  ollama pull $DEFAULT_MODEL"
        fi
    fi
}

start_ollama_service() {
    if brew services list 2>/dev/null | grep -q "ollama.*started"; then
        ok "Ollama service already running"
    else
        info "Setting Ollama to start automatically..."
        brew services start ollama
        sleep 2
        if curl -s http://localhost:11434/ >/dev/null 2>&1; then
            ok "Ollama service started and running"
        else
            info "Waiting for Ollama to start..."
            sleep 3
            if curl -s http://localhost:11434/ >/dev/null 2>&1; then
                ok "Ollama service is running"
            else
                warn "Ollama may need a moment to start. It will be ready when you open the app."
            fi
        fi
    fi
}

pull_default_model() {
    if ollama list 2>/dev/null | grep -q "$DEFAULT_MODEL"; then
        ok "Model $DEFAULT_MODEL already downloaded"
    else
        info "Downloading AI model ($DEFAULT_MODEL, ~1.9 GB)..."
        info "This may take a few minutes depending on your internet speed."
        if ollama pull "$DEFAULT_MODEL"; then
            ok "Model $DEFAULT_MODEL ready"
        else
            warn "Model download failed. You can download later in the app or run:"
            echo "  ollama pull $DEFAULT_MODEL"
        fi
    fi
}

if command -v ollama >/dev/null 2>&1 || command -v brew >/dev/null 2>&1; then
    install_ollama
    if command -v ollama >/dev/null 2>&1; then
        start_ollama_service
        pull_default_model
    fi
else
    warn "Homebrew not found. To enable AI summaries, install Ollama manually:"
    echo "  1. Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "  2. brew install ollama && brew services start ollama"
    echo "  3. ollama pull $DEFAULT_MODEL"
    echo ""
fi

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
echo "║                                      ║"
if command -v ollama >/dev/null 2>&1; then
echo "║  AI Summary: Ollama ready            ║"
else
echo "║  AI Summary: install Ollama to use   ║"
fi
echo "╚══════════════════════════════════════╝"
echo ""
