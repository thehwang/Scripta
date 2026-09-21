#!/bin/bash
# Scripta Local Dev Installer
#
# Build from source, sign with a local dev certificate, install to /Applications,
# and reset TCC permissions so mic / screen recording prompts work reliably.
# No CI or GitHub release download required.
#
# Usage (from repo root or scripts/):
#   bash scripts/install-local.sh
#   bash scripts/install-local.sh --no-launch
#   SCRIPTA_SKIP_BUILD=1 bash scripts/install-local.sh
#   SCRIPTA_WITH_DEPS=1 bash scripts/install-local.sh   # also install Ollama + models
#   bash scripts/install-local.sh --reset-permissions   # wipe TCC grants (opt-in)
#   bash scripts/install-local.sh --user-install          # install to ~/Applications (not recommended)
#
# Why not `swift run`?
#   Unsigned debug binaries often fail TCC (mic / screen recording). This script
#   packages a signed .app bundle like production install.sh does.
set -euo pipefail

APP="Scripta"
BUNDLE_ID="com.thehwang.scripta"
CERT_NAME="Scripta Dev"
ENTITLEMENTS="Scripta.entitlements"
INSTALL_DIR="${SCRIPTA_INSTALL_DIR:-/Applications}"
APP_PATH="$INSTALL_DIR/$APP.app"
STAGING_DIR=""
USER_INSTALL=0
RESET_PERMISSIONS=0

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

NO_LAUNCH=0
SKIP_BUILD=0
WITH_DEPS=0
BUILD_CONFIG="release"

usage() {
    sed -n '2,14p' "$0" | sed 's/^# //'
    echo ""
    echo "Options:"
    echo "  --no-launch              Install/sign only; do not open the app"
    echo "  --skip-build             Re-sign and reinstall existing build/dist app"
    echo "  --reset-permissions      Reset mic/screen/speech TCC grants (default: keep)"
    echo "  --user-install           Install to ~/Applications (screen recording may fail)"
    echo "  --with-deps              Also run Ollama + Whisper setup (like install.sh)"
    echo "  --debug                  Build debug configuration instead of release"
    echo "  -h, --help               Show this help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-launch) NO_LAUNCH=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --reset-permissions) RESET_PERMISSIONS=1 ;;
        --user-install) USER_INSTALL=1 ;;
        --with-deps) WITH_DEPS=1 ;;
        --debug) BUILD_CONFIG="debug" ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ "${SCRIPTA_NO_LAUNCH:-0}" = "1" ] && NO_LAUNCH=1
[ "${SCRIPTA_SKIP_BUILD:-0}" = "1" ] && SKIP_BUILD=1
[ "${SCRIPTA_RESET_PERMISSIONS:-0}" = "1" ] && RESET_PERMISSIONS=1
[ "${SCRIPTA_USER_INSTALL:-0}" = "1" ] && USER_INSTALL=1
[ "${SCRIPTA_WITH_DEPS:-0}" = "1" ] && WITH_DEPS=1

if [ "$USER_INSTALL" = "1" ]; then
    INSTALL_DIR="$HOME/Applications"
    APP_PATH="$INSTALL_DIR/$APP.app"
fi

if [ "$INSTALL_DIR" != "/Applications" ] && [ "$USER_INSTALL" != "1" ] && [ -n "${SCRIPTA_INSTALL_DIR:-}" ]; then
    warn "Custom install dir: $INSTALL_DIR"
    warn "Screen Recording is unreliable outside /Applications — use default or --user-install knowingly."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGING_DIR="$PROJECT_DIR/build/local-install"
STAGING_APP="$STAGING_DIR/$APP.app"

cleanup() {
    :
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Scripta Local Dev Installer      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

MACOS_VER=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d. -f1)
info "Detected macOS $MACOS_VER"
info "Project: $PROJECT_DIR"

if [ "$MACOS_MAJOR" -lt 14 ]; then
    fail "Scripta requires macOS 14 (Sonoma) or later. You have macOS $MACOS_VER."
fi

cd "$PROJECT_DIR"

[ -f "$ENTITLEMENTS" ] || fail "Missing $ENTITLEMENTS in $PROJECT_DIR"
[ -f "Sources/Scripta/Info.plist" ] || fail "Run this script from the Scripta repo."

select_xcode() {
    local candidates=(
        /Applications/Xcode_26.6.app
        /Applications/Xcode_26.app
        /Applications/Xcode_16.4.app
        /Applications/Xcode_16.0.app
        /Applications/Xcode.app
    )
    local chosen=""
    for xcode in "${candidates[@]}"; do
        [ -d "$xcode" ] || continue
        local dev="$xcode/Contents/Developer"
        local sdk
        sdk="$(ls "$dev/Platforms/MacOSX.platform/Developer/SDKs" 2>/dev/null | grep '^MacOSX' | sort -V | tail -1 || true)"
        local major
        major="$(echo "${sdk:-MacOSX0.sdk}" | sed 's/MacOSX//;s/.sdk//' | cut -d. -f1)"
        if [ "${major:-0}" -ge 15 ]; then
            export DEVELOPER_DIR="$dev"
            export SCRIPTA_HAS_TRANSLATION=1
            if [ "${major:-0}" -ge 26 ]; then
                export SCRIPTA_HAS_FM_SUGGESTIONS=1
            else
                unset SCRIPTA_HAS_FM_SUGGESTIONS
            fi
            chosen="$xcode"
            info "Using $dev (SDK $sdk, translation enabled)"
            if [ "${major:-0}" -ge 26 ]; then
                info "Foundation Models available (Xcode 26+ SDK)"
            fi
            return
        fi
    done

    export DEVELOPER_DIR="$(xcode-select -p)"
    unset SCRIPTA_HAS_TRANSLATION
    unset SCRIPTA_HAS_FM_SUGGESTIONS
    warn "No Xcode with macOS 15+ SDK found — translation will be disabled"
    warn "Install Xcode 16+ for translation; Xcode 26+ for meeting suggestions"
}

swift_cmd() {
    if [ -n "${DEVELOPER_DIR:-}" ]; then
        DEVELOPER_DIR="$DEVELOPER_DIR" \
            SCRIPTA_HAS_TRANSLATION="${SCRIPTA_HAS_TRANSLATION:-}" \
            SCRIPTA_HAS_FM_SUGGESTIONS="${SCRIPTA_HAS_FM_SUGGESTIONS:-}" \
            swift "$@"
    else
        SCRIPTA_HAS_TRANSLATION="${SCRIPTA_HAS_TRANSLATION:-}" \
            SCRIPTA_HAS_FM_SUGGESTIONS="${SCRIPTA_HAS_FM_SUGGESTIONS:-}" \
            swift "$@"
    fi
}

ensure_dev_certificate() {
    info "Ensuring local code signing certificate..."
    bash "$SCRIPT_DIR/setup-cert.sh"
    if ! security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
        fail "Certificate '$CERT_NAME' not found. Open Keychain Access and trust it for Code Signing."
    fi
    ok "Certificate '$CERT_NAME' ready"
}

build_whisper_if_needed() {
    if [ -f Sources/CWhisper/lib/libwhisper.a ]; then
        ok "whisper.cpp library already built"
        return
    fi
    info "Building whisper.cpp (first time only)..."
    make whisper-lib
}

package_app() {
    local bin_path
    bin_path="$(swift_cmd build -c "$BUILD_CONFIG" --show-bin-path)"
    local src_bin="$bin_path/$APP"

    [ -f "$src_bin" ] || fail "Binary not found at $src_bin"

    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_APP/Contents/MacOS"
    mkdir -p "$STAGING_APP/Contents/Resources"

    cp "$src_bin" "$STAGING_APP/Contents/MacOS/$APP"
    cp "Sources/Scripta/Info.plist" "$STAGING_APP/Contents/Info.plist"
    if [ -f "Resources/AppIcon.icns" ]; then
        cp "Resources/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"
    fi

    ok "Packaged $STAGING_APP"
}

sign_app() {
    local target="$1"
    info "Clearing quarantine attributes..."
    xattr -cr "$target"

    info "Signing with '$CERT_NAME'..."
    /usr/bin/codesign --force --sign "$CERT_NAME" \
        --entitlements "$PROJECT_DIR/$ENTITLEMENTS" \
        --deep "$target"

    if ! codesign --verify --deep --strict "$target" 2>/dev/null; then
        fail "Code signature verification failed for $target"
    fi
    ok "Signed and verified: $target"
}

build_and_package() {
    select_xcode
    ensure_dev_certificate
    build_whisper_if_needed

    info "Building $APP ($BUILD_CONFIG)..."
    swift_cmd build -c "$BUILD_CONFIG"
    package_app
    sign_app "$STAGING_APP"
}

use_existing_build() {
    local existing=""
    if [ -d "$PROJECT_DIR/build/dist/$APP.app" ]; then
        existing="$PROJECT_DIR/build/dist/$APP.app"
    elif [ -d "$PROJECT_DIR/build/$APP.app" ]; then
        existing="$PROJECT_DIR/build/$APP.app"
    elif [ -d "$STAGING_APP" ]; then
        existing="$STAGING_APP"
    fi

    [ -n "$existing" ] || fail "--skip-build set but no existing $APP.app found under build/"

    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$existing" "$STAGING_APP"
    ensure_dev_certificate
    sign_app "$STAGING_APP"
    ok "Using existing build: $existing"
}

stop_running_app() {
    if pgrep -x "$APP" >/dev/null 2>&1; then
        info "Stopping running $APP..."
        killall "$APP" 2>/dev/null || true
        sleep 1
    fi
}

install_to_applications() {
    stop_running_app

    if [ -d "$APP_PATH" ]; then
        info "Removing old installation at $APP_PATH ..."
        rm -rf "$APP_PATH"
    fi

    if [ ! -d "$INSTALL_DIR" ]; then
        info "Creating install directory $INSTALL_DIR ..."
        mkdir -p "$INSTALL_DIR"
    fi

    info "Installing to $APP_PATH ..."
    cp -R "$STAGING_APP" "$APP_PATH"
    sign_app "$APP_PATH"
    ok "Installed to $APP_PATH"
}

reset_permissions() {
    if [ "$RESET_PERMISSIONS" != "1" ]; then
        info "Keeping existing TCC grants (pass --reset-permissions to wipe)"
        touch "$APP_PATH"
        return
    fi

    info "Resetting TCC permissions and onboarding flag..."
    defaults delete "$BUNDLE_ID" Scripta.permissionsOnboardingComplete 2>/dev/null || true
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset SpeechRecognition "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset AppleEvents "$BUNDLE_ID" 2>/dev/null || true

    touch "$APP_PATH"
    killall Dock 2>/dev/null || true
    ok "Permissions reset for $BUNDLE_ID"
}

open_screen_recording_settings() {
    info "Opening Screen Recording settings — add Scripta if missing:"
    echo "  → $APP_PATH"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null \
        || open "/System/Applications/System Settings.app" 2>/dev/null \
        || true
}

print_permission_notes() {
    echo ""
    if [ "$INSTALL_DIR" != "/Applications" ]; then
        warn "Installed outside /Applications — System Audio (screen recording) often fails here."
        warn "Re-run without --user-install to install to /Applications instead."
        echo ""
    fi
    warn "First launch: enable System Audio in the app, then confirm in System Settings."
    echo "  1. Click Enable on the first card (System Audio)"
    echo "  2. In System Settings → Screen Recording, enable $APP"
    echo "     Path must be: $APP_PATH"
    echo "  3. Quit and reopen $APP if the toggle does not stick"
    echo ""
    echo "  Re-sign / new bundle? Use: bash scripts/install-local.sh --reset-permissions"
    echo ""
}

setup_whisper_model() {
    local whisper_model_dir="$HOME/Library/Application Support/Scripta/models"
    local whisper_model="ggml-base.bin"
    local whisper_model_path="$whisper_model_dir/$whisper_model"
    local whisper_model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$whisper_model"

    if [ -f "$whisper_model_path" ]; then
        ok "Whisper model already present"
        return
    fi

    info "Downloading Whisper model ($whisper_model, ~142 MB)..."
    mkdir -p "$whisper_model_dir"
    if curl -fSL --progress-bar -o "$whisper_model_path" "$whisper_model_url"; then
        ok "Whisper model ready"
    else
        warn "Whisper download failed — app will prompt on first launch"
    fi
}

setup_ollama_deps() {
    [ "$WITH_DEPS" = "1" ] || return 0

    local default_model="qwen2.5:3b"

    if command -v ollama >/dev/null 2>&1; then
        :
    elif command -v brew >/dev/null 2>&1; then
        info "Installing Ollama..."
        brew install ollama
    else
        warn "Skipping Ollama setup (install Homebrew or run scripts/install.sh)"
        return
    fi

    if ! brew services list 2>/dev/null | grep -q "ollama.*started"; then
        brew services start ollama 2>/dev/null || true
        sleep 2
    fi

    if ollama list 2>/dev/null | grep -q "$default_model"; then
        ok "Ollama model $default_model already present"
    else
        info "Pulling $default_model ..."
        ollama pull "$default_model" || warn "Could not pull $default_model"
    fi
}

if [ "$SKIP_BUILD" = "1" ]; then
    use_existing_build
else
    build_and_package
fi

install_to_applications
reset_permissions
setup_whisper_model
setup_ollama_deps
open_screen_recording_settings
print_permission_notes

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?')"

if [ "$NO_LAUNCH" = "1" ]; then
    ok "Local install complete (not launched). Version $VERSION ($BUILD_NUM)"
    echo "  open \"$APP_PATH\""
    exit 0
fi

info "Launching $APP v$VERSION ($BUILD_NUM)..."
open "$APP_PATH"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Local install complete!             ║${NC}"
echo -e "${BOLD}║                                      ║${NC}"
printf "${BOLD}║  Signed with: %-22s ║${NC}\n" "$CERT_NAME"
echo -e "${BOLD}║  Grant System Audio when prompted.   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""
