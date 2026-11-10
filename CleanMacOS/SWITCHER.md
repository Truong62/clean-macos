# App Switcher and Dock Preview

Both features and every optional toggle start off. Settings are stored together as JSON under `switcher.settings`; missing fields retain their defaults.

The App Switcher page follows Windows in the System group. It provides window previews, large icons and a capture-free simple list, keyboard navigation, search, recent-use order, app rules, permission controls and separate switcher/Dock sizing. The Command Bar includes Switch Windows when enabled.

The keyboard tap runs on a dedicated thread. Enumeration and capture do not run in its callback. Dock hover uses a separate listen-only tap. ScreenCaptureKit screenshots share a serial capture gate with Agent Demo screenshots, a memory-only 48-image/64-MB cache and capture backoff. AX helpers provide close, minimize, restore and activation. Pinned previews refresh every 750 ms; Dock cards can be dragged to a display.

System shortcut takeover is a separate opt-in, gated on dynamically resolved WindowServer functions, Accessibility, a live tap and an active session. A headless child watches a pipe and restores the held symbolic hotkeys on parent exit. A persisted marker also supports recovery on the next launch. Secure input restores native shortcuts rather than installing Carbon stand-ins.

## Remaining specification gaps

This implementation uses AX enumeration and cooperative activation. It does not implement private Space topology and synthetic Space traversal, private process-fronting, excluded-from-cycling tags, remote-token title lookup, compatibility-layer/helper ownership rules, or the full server-only ghost-window recovery path. Offscreen status is an approximation for the other-desktop badge.

Capture uses ScreenCaptureKit, without the private capture route, clipped-band detection or Stage Manager artwork correction. The experimental CoreDock hold-revealed option is not implemented. Icon layouts use a scrolling grid rather than the specified single-row edge-paging behavior. Liquid Glass styling is not implemented. Secure-input Carbon stand-ins and IOKit secure-input notifications are not implemented; secure input is polled and hands shortcuts back to macOS.

## Verification

The required Cargo/SwiftPM command passes 44 Rust tests and 403 Swift tests, including 41 new switcher tests. New and changed Swift sources compile without warnings. Existing unrelated Swift warnings and Rust standard-library deployment-target linker warnings remain in a clean build.

The pre-seeded SwiftPM cache required removal because it referenced the original checkout. On this Command Line Tools installation, KeyboardShortcuts 2.3.0 also requires removing its three `#Preview` blocks from the local `.build` checkout because the Xcode preview macro plugin is unavailable. This cache-only adjustment changes no production dependency code and must be repeated after deleting that checkout when building with the same tools.

The app was not launched. Permission prompts, live taps, crash recovery, WindowServer calls, Dock interaction, Spaces, minimized/full-screen activation, screen-lock transitions and two-display dragging remain unverified on the Apple-silicon Mac mini with two external DELL displays. No battery or fan code was added.
