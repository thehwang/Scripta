APP=MeetingPilot
ENTITLEMENTS=MeetingPilot.entitlements
INSTALL_DIR=/Applications
CERT_NAME=MeetingPilot Dev

.PHONY: build run install setup-cert test clean reset-permissions

build:
	swift build

setup-cert:
	@if security find-identity -v -p codesigning | grep -q "$(CERT_NAME)"; then \
		echo "Certificate '$(CERT_NAME)' already exists."; \
	else \
		echo "Creating self-signed certificate '$(CERT_NAME)' ..."; \
		TMPDIR=$$(mktemp -d); \
		cat > "$$TMPDIR/cert.cfg" <<-'CERTCFG'; \
		[ req ] \
		default_bits       = 2048 \
		distinguished_name = dn \
		prompt             = no \
		x509_extensions    = codesign \
		[ dn ] \
		CN = MeetingPilot Dev \
		[ codesign ] \
		keyUsage           = digitalSignature \
		extendedKeyUsage   = codeSigning \
		CERTCFG \
		openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
			-config "$$TMPDIR/cert.cfg" \
			-keyout "$$TMPDIR/key.pem" -out "$$TMPDIR/cert.pem" 2>/dev/null; \
		openssl pkcs12 -export -inkey "$$TMPDIR/key.pem" -in "$$TMPDIR/cert.pem" \
			-out "$$TMPDIR/cert.p12" -passout pass:temp 2>/dev/null; \
		security import "$$TMPDIR/cert.p12" -k ~/Library/Keychains/login.keychain-db \
			-P temp -T /usr/bin/codesign 2>/dev/null; \
		rm -rf "$$TMPDIR"; \
		echo "Certificate created. You may need to open Keychain Access and trust it:"; \
		echo "  1. Open Keychain Access"; \
		echo "  2. Find 'MeetingPilot Dev' in 'login' keychain"; \
		echo "  3. Double-click → Trust → Always Trust"; \
	fi

run: setup-cert
	@set -e; \
	swift build; \
	BIN_PATH="$$(swift build --show-bin-path)"; \
	APP_BUNDLE="$$BIN_PATH/$(APP).app"; \
	CONTENTS_DIR="$$APP_BUNDLE/Contents"; \
	MACOS_DIR="$$CONTENTS_DIR/MacOS"; \
	mkdir -p "$$MACOS_DIR"; \
	cp "$$BIN_PATH/$(APP)" "$$MACOS_DIR/$(APP)"; \
	cp "Sources/MeetingPilot/Info.plist" "$$CONTENTS_DIR/Info.plist"; \
	/usr/bin/codesign --force --sign "$(CERT_NAME)" --entitlements $(ENTITLEMENTS) --deep "$$APP_BUNDLE"; \
	open "$$APP_BUNDLE"

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
	/usr/bin/codesign --force --sign "$(CERT_NAME)" --entitlements $(ENTITLEMENTS) --deep "$$APP_BUNDLE"; \
	echo ""; \
	echo "Installed to $(INSTALL_DIR)/$(APP).app"; \
	echo "Signed with certificate '$(CERT_NAME)'"; \
	echo ""; \
	echo "First launch: open /Applications/$(APP).app"; \
	echo "Grant Microphone + Screen Recording when prompted."

test:
	swift test

clean:
	rm -rf .build

reset-permissions:
	tccutil reset ScreenCapture com.hwang.meetingpilot
	tccutil reset Microphone com.hwang.meetingpilot
	@echo "TCC permissions reset. Re-launch the app to re-grant."
