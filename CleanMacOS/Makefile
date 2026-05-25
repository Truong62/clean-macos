.PHONY: build run release clean

# Quick dev builds via SwiftPM. Packaging/release (signed DMG + Sparkle
# appcast) is handled by scripts/package.sh (XcodeGen + xcodebuild + DMG).

build:
	swift build

run:
	swift run

release:
	swift build -c release

clean:
	swift package clean
