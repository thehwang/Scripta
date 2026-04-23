APP=MeetingPilot
ENTITLEMENTS=MeetingPilot.entitlements
INSTALL_DIR=/Applications
SIGN_IDENTITY=MeetingPilot Dev

.PHONY: build run install test clean reset-permissions

build:
	swift build

run:
	@set -e; \
	swift build; \
	BIN_PATH="$$(swift build --show-bin-path)"; \
	APP_BUNDLE="$$BIN_PATH/$(APP).app"; \
	CONTENTS_DIR="$$APP_BUNDLE/Contents"; \
	MACOS_DIR="$$CONTENTS_DIR/MacOS"; \
	mkdir -p "$$MACOS_DIR"; \
	cp "$$BIN_PATH/$(APP)" "$$MACOS_DIR/$(APP)"; \
	cp "Sources/MeetingPilot/Info.plist" "$$CONTENTS_DIR/Info.plist"; \
	/usr/bin/codesign --force --sign "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --deep "$$APP_BUNDLE"; \
	open "$$APP_BUNDLE"

install:
	@set -e; \
	swift build -c release; \
	BIN_PATH="$$(swift build -c release --show-bin-path)"; \
	APP_BUNDLE="$(INSTALL_DIR)/$(APP).app"; \
	CONTENTS_DIR="$$APP_BUNDLE/Contents"; \
	MACOS_DIR="$$CONTENTS_DIR/MacOS"; \
	mkdir -p "$$MACOS_DIR"; \
	cp "$$BIN_PATH/$(APP)" "$$MACOS_DIR/$(APP)"; \
	cp "Sources/MeetingPilot/Info.plist" "$$CONTENTS_DIR/Info.plist"; \
	/usr/bin/codesign --force --sign "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --deep "$$APP_BUNDLE"; \
	echo "Installed to $(INSTALL_DIR)/$(APP).app (signed with $(SIGN_IDENTITY))"

test:
	swift test

clean:
	rm -rf .build

reset-permissions:
	tccutil reset ScreenCapture com.hwang.meetingpilot
	tccutil reset Microphone com.hwang.meetingpilot
	@echo "TCC permissions reset. Re-launch the app to re-grant."
