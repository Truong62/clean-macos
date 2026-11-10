.PHONY: build run release clean test-clt rust

# Quick dev builds via SwiftPM. Packaging/release (signed DMG + Sparkle
# appcast) is handled by scripts/package.sh (XcodeGen + xcodebuild + DMG).

rust:
	cargo build --release --manifest-path Rust/Cargo.toml

build: rust
	swift build

run: rust
	swift run

release: rust
	swift build -c release

clean:
	swift package clean

CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer

test-clt: rust
	cargo test --quiet --manifest-path Rust/Cargo.toml
	swift test --disable-xctest -Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks \
	  -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib
