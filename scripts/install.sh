#!/bin/bash
# Scripta Installer
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/thehwang/Scripta/main/scripts/install.sh | bash
#
# With Gemma 4 (extra 7.2 GB, 128K context, recommended for hour-long meetings):
#   SCRIPTA_INSTALL_GEMMA4=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/thehwang/Scripta/main/scripts/install.sh)"
#
# Or run locally:
#   bash install.sh                       (auto-download latest release)
#   bash install.sh Scripta-macos15.zip   (use local zip)
set -e

APP="Scripta"
BUNDLE_ID="com.thehwang.scripta"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP.app"
REPO="thehwang/Scripta"
TMPDIR_INSTALL="${TMPDIR:-/tmp}/scripta-install-$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
fail()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

cleanup() { rm -rf "$TMPDIR_INSTALL"; }
trap cleanup EXIT

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Scripta Installer            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── Detect macOS ─────────────────────────────────────────────────────
MACOS_VER=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d. -f1)
info "Detected macOS $MACOS_VER"

if [ "$MACOS_MAJOR" -lt 14 ]; then
    fail "Scripta requires macOS 14 (Sonoma) or later. You have macOS $MACOS_VER."
fi

# ── Locate or download Scripta.app ───────────────────────────────────
find_app() {
    local dir="$1"
    [ -d "$dir/$APP.app" ] && echo "$dir/$APP.app" && return
    local zip=$(find "$dir" -maxdepth 1 -name "$APP*.zip" 2>/dev/null | head -1)
    if [ -n "$zip" ]; then
        info "Extracting $(basename "$zip") ..."
        unzip -qo "$zip" -d "$dir"
        local found=$(find "$dir" -maxdepth 2 -name "$APP.app" -type d | head -1)
        [ -n "$found" ] && echo "$found" && return
    fi
    return 1
}

SOURCE_APP=""

if [ -n "$1" ] && [ -f "$1" ]; then
    mkdir -p "$TMPDIR_INSTALL"
    info "Using local file: $1"
    cp "$1" "$TMPDIR_INSTALL/"
    SOURCE_APP=$(find_app "$TMPDIR_INSTALL") || true
elif [ -n "$1" ] && [ -d "$1" ]; then
    SOURCE_APP="$1"
fi

if [ -z "$SOURCE_APP" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
    SOURCE_APP=$(find_app "$SCRIPT_DIR") || true
fi

if [ -z "$SOURCE_APP" ]; then
    SOURCE_APP=$(find_app "$(pwd)") || true
fi

if [ -z "$SOURCE_APP" ]; then
    info "Downloading latest release from GitHub..."
    mkdir -p "$TMPDIR_INSTALL"

    ASSET_NAME="Scripta-macos${MACOS_MAJOR}.zip"
    DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$ASSET_NAME"

    info "Trying $ASSET_NAME ..."
    if ! curl -fSL --progress-bar -o "$TMPDIR_INSTALL/$ASSET_NAME" "$DOWNLOAD_URL" 2>&1; then
        if [ "$MACOS_MAJOR" -ge 15 ]; then
            ASSET_NAME="Scripta-macos15.zip"
        else
            ASSET_NAME="Scripta-macos14.zip"
        fi
        DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$ASSET_NAME"
        info "Retrying with $ASSET_NAME ..."
        curl -fSL --progress-bar -o "$TMPDIR_INSTALL/$ASSET_NAME" "$DOWNLOAD_URL" \
            || fail "Download failed. Check https://github.com/$REPO/releases for available files."
    fi

    ok "Downloaded $ASSET_NAME"
    SOURCE_APP=$(find_app "$TMPDIR_INSTALL") \
        || fail "Could not find $APP.app in downloaded archive."
fi

info "Source: $SOURCE_APP"

# ── Install ──────────────────────────────────────────────────────────
if pgrep -x "$APP" >/dev/null 2>&1; then
    info "Stopping running $APP..."
    killall "$APP" 2>/dev/null || true
    sleep 1
fi

if [ -d "$APP_PATH" ]; then
    info "Removing old installation..."
    rm -rf "$APP_PATH"
fi

info "Installing to $INSTALL_DIR..."
cp -R "$SOURCE_APP" "$APP_PATH"

xattr -cr "$APP_PATH"

info "Resetting permissions for clean authorization..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true

touch "$APP_PATH"
killall Dock 2>/dev/null || true

ok "Installed to $APP_PATH"
echo ""

# ── Ollama (AI Summary) ─────────────────────────────────────────────
DEFAULT_MODEL="qwen2.5:3b"
GEMMA4_MODEL="gemma4:e2b"
OLLAMA_MIN_FOR_GEMMA4="0.20.0"

version_ge() {
    [ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

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
        local retries=0
        while [ $retries -lt 5 ]; do
            if curl -s http://localhost:11434/ >/dev/null 2>&1; then
                ok "Ollama service is running"
                return
            fi
            retries=$((retries + 1))
            sleep 1
        done
        warn "Ollama may need a moment to start. It will be ready when you open the app."
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

# Optional: pull Gemma 4 E2B for long-meeting / reasoning use cases.
# Enable with: SCRIPTA_INSTALL_GEMMA4=1 curl -fsSL .../install.sh | bash
pull_gemma4_model() {
    [ "${SCRIPTA_INSTALL_GEMMA4:-0}" = "1" ] || return 0

    local ollama_ver
    ollama_ver=$(ollama --version 2>/dev/null | awk '{print $NF}' | tr -d '[:alpha:]')
    if [ -n "$ollama_ver" ] && ! version_ge "$ollama_ver" "$OLLAMA_MIN_FOR_GEMMA4"; then
        warn "Ollama $ollama_ver is older than $OLLAMA_MIN_FOR_GEMMA4 — Gemma 4 requires upgrade."
        warn "Run: brew upgrade ollama  (then re-run install with SCRIPTA_INSTALL_GEMMA4=1)"
        return 0
    fi

    if ollama list 2>/dev/null | grep -q "$GEMMA4_MODEL"; then
        ok "Gemma 4 model $GEMMA4_MODEL already downloaded"
    else
        info "Downloading Gemma 4 ($GEMMA4_MODEL, ~7.2 GB, 128K context)..."
        info "This is a larger download — recommended for hour-long meetings."
        if ollama pull "$GEMMA4_MODEL"; then
            ok "Gemma 4 $GEMMA4_MODEL ready — select it in Scripta's model picker."
        else
            warn "Gemma 4 download failed. You can download later in the app or run:"
            echo "  ollama pull $GEMMA4_MODEL"
        fi
    fi
}

if command -v ollama >/dev/null 2>&1 || command -v brew >/dev/null 2>&1; then
    install_ollama
    if command -v ollama >/dev/null 2>&1; then
        start_ollama_service
        pull_default_model
        pull_gemma4_model
    fi
else
    warn "Homebrew not found. To enable AI summaries, install Ollama manually:"
    echo "  1. Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "  2. brew install ollama && brew services start ollama"
    echo "  3. ollama pull $DEFAULT_MODEL"
    echo ""
fi

# ── Whisper model (mic transcription) ─────────────────────────────────
WHISPER_MODEL_DIR="$HOME/Library/Application Support/Scripta/models"
WHISPER_MODEL="ggml-base.bin"
WHISPER_MODEL_PATH="$WHISPER_MODEL_DIR/$WHISPER_MODEL"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"

if [ -f "$WHISPER_MODEL_PATH" ]; then
    ok "Whisper model already downloaded ($WHISPER_MODEL)"
else
    info "Downloading Whisper speech model ($WHISPER_MODEL, ~142 MB)..."
    info "This enables 100% local microphone transcription via whisper.cpp."
    mkdir -p "$WHISPER_MODEL_DIR"
    if curl -fSL --progress-bar -o "$WHISPER_MODEL_PATH" "$WHISPER_MODEL_URL"; then
        ok "Whisper model downloaded to $WHISPER_MODEL_PATH"
    else
        warn "Whisper model download failed. The app will prompt you to download on first launch."
        warn "Or manually download:"
        echo "  curl -L -o \"$WHISPER_MODEL_PATH\" $WHISPER_MODEL_URL"
    fi
fi
echo ""

# ── macOS version notes ──────────────────────────────────────────────
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

# ── Launch ───────────────────────────────────────────────────────────
info "Launching $APP..."
open "$APP_PATH"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Installation complete!              ║${NC}"
echo -e "${BOLD}║                                      ║${NC}"
echo -e "${BOLD}║  Grant permissions when prompted.    ║${NC}"
echo -e "${BOLD}║  If Screen Recording fails, quit     ║${NC}"
echo -e "${BOLD}║  and reopen after granting.          ║${NC}"
echo -e "${BOLD}║                                      ║${NC}"
if command -v ollama >/dev/null 2>&1; then
echo -e "${BOLD}║  AI Summary: Ollama ready            ║${NC}"
else
echo -e "${BOLD}║  AI Summary: install Ollama to use   ║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""
