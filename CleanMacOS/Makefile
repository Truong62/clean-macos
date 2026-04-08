.PHONY: build run clean release app

APP_NAME = Clean macOS
BUNDLE_ID = com.cleanmacos.app
BUILD_DIR = .build
RELEASE_DIR = $(BUILD_DIR)/release
APP_DIR = $(APP_NAME).app

build:
	swift build

run:
	swift run

release:
	swift build -c release

app: release
	@echo "Creating $(APP_DIR)..."
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(APP_DIR)/Contents/MacOS"
	@mkdir -p "$(APP_DIR)/Contents/Resources"
	@cp $(RELEASE_DIR)/CleanMacOS "$(APP_DIR)/Contents/MacOS/CleanMacOS"
	@echo '<?xml version="1.0" encoding="UTF-8"?>\n\
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n\
<plist version="1.0">\n\
<dict>\n\
	<key>CFBundleExecutable</key>\n\
	<string>CleanMacOS</string>\n\
	<key>CFBundleIdentifier</key>\n\
	<string>$(BUNDLE_ID)</string>\n\
	<key>CFBundleName</key>\n\
	<string>$(APP_NAME)</string>\n\
	<key>CFBundleVersion</key>\n\
	<string>1.0.0</string>\n\
	<key>CFBundleShortVersionString</key>\n\
	<string>1.0.0</string>\n\
	<key>CFBundlePackageType</key>\n\
	<string>APPL</string>\n\
	<key>LSMinimumSystemVersion</key>\n\
	<string>14.0</string>\n\
	<key>NSHighResolutionCapable</key>\n\
	<true/>\n\
	<key>LSUIElement</key>\n\
	<false/>\n\
</dict>\n\
</plist>' > "$(APP_DIR)/Contents/Info.plist"
	@echo "✓ $(APP_DIR) created"

clean:
	swift package clean
	rm -rf "$(APP_DIR)"
