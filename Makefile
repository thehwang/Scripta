APP=MeetingPilot
ENTITLEMENTS=MeetingPilot.entitlements
INSTALL_DIR=/Applications
CERT_NAME=MeetingPilot Dev
DEV_BUNDLE=build/$(APP).app

.PHONY: build run install setup-cert test clean reset-permissions

build:
	swift build

setup-cert:
	@bash scripts/setup-cert.sh

run: setup-cert
	@set -e; \
	echo "Building ..."; \
	swift build 2>&1; \
	BIN_PATH="$$(swift build --show-bin-path)"; \
	SRC_BIN="$$BIN_PATH/$(APP)"; \
	CONTENTS_DIR="$(DEV_BUNDLE)/Contents"; \
	MACOS_DIR="$$CONTENTS_DIR/MacOS"; \
	DST_BIN="$$MACOS_DIR/$(APP)"; \
	HASH_FILE="build/.binary_hash"; \
	mkdir -p "$$MACOS_DIR"; \
	NEW_HASH=$$(shasum -a 256 "$$SRC_BIN" | cut -d' ' -f1); \
	OLD_HASH=""; \
	if [ -f "$$HASH_FILE" ]; then OLD_HASH=$$(cat "$$HASH_FILE"); fi; \
	if [ "$$NEW_HASH" != "$$OLD_HASH" ] || ! codesign --verify --deep --strict "$(DEV_BUNDLE)" 2>/dev/null; then \
		echo "Binary changed — copying and signing with Hardened Runtime ..."; \
		cp "$$SRC_BIN" "$$DST_BIN"; \
		cp "Sources/MeetingPilot/Info.plist" "$$CONTENTS_DIR/Info.plist"; \
		echo "$$NEW_HASH" > "$$HASH_FILE"; \
		/usr/bin/codesign --force --sign "$(CERT_NAME)" \
			--entitlements $(ENTITLEMENTS) \
			--options runtime \
			--deep "$(DEV_BUNDLE)"; \
		echo "Signed. TCC may ask for permissions on first launch."; \
	else \
		echo "Binary unchanged — skipping re-sign (TCC permissions preserved)."; \
	fi; \
	echo "Launching $(DEV_BUNDLE) ..."; \
	open "$(DEV_BUNDLE)"

install: setup-cert
	@set -e; \
	echo "Building release binary ..."; \
	swift build -c release; \
	BIN_PATH="$$(swift build -c release --show-bin-path)"; \
	APP_BUNDLE="$(INSTALL_DIR)/$(APP).app"; \
	CONTENTS_DIR="$$APP_BUNDLE/Contents"; \
	MACOS_DIR="$$CONTENTS_DIR/MacOS"; \
	mkdir -p "$$MACOS_DIR"; \
	cp "$$BIN_PATH/$(APP)" "$$MACOS_DIR/$(APP)"; \
	cp "Sources/MeetingPilot/Info.plist" "$$CONTENTS_DIR/Info.plist"; \
	xattr -cr "$$APP_BUNDLE"; \
	/usr/bin/codesign --force --sign "$(CERT_NAME)" \
		--entitlements $(ENTITLEMENTS) \
		--options runtime \
		--deep "$$APP_BUNDLE"; \
	echo ""; \
	echo "Installed to $(INSTALL_DIR)/$(APP).app"; \
	echo "Signed with Hardened Runtime + certificate '$(CERT_NAME)'"; \
	echo ""; \
	echo "First launch: open /Applications/$(APP).app"; \
	echo "Grant Microphone + Screen Recording when prompted."

test:
	swift test

clean:
	rm -rf .build build

reset-permissions:
	tccutil reset ScreenCapture com.hwang.meetingpilot
	tccutil reset Microphone com.hwang.meetingpilot
	@echo ""
	@echo "TCC permissions reset. Re-launch the app to re-grant."
	@echo "If Screen Recording doesn't work, add the app manually:"
	@echo "  System Settings → Privacy & Security → Screen Recording → + → select MeetingPilot"
