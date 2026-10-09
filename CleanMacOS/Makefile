.PHONY: build run release clean test-clt

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

CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer

test-clt:
	swift test --disable-xctest -Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks \
	  -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib
