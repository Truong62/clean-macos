# Screenshot capture

The Screenshot page lives immediately before Screen Record. All new toggles and shortcuts default to off. Manual buttons remain available. Capture requests preflight Screen Recording; color and text tools retain their existing system fallbacks. Existing editor actions call ScreenshotEditorBridge.open without changing its implementation.

The settings object decodes absent fields using defaults. Geometry, pixel sampling, repeat regions, window filtering, overlap matching, reverse-scroll tracking, placement, naming, retention, limits and link validation are independent of AppKit UI. ScreenshotTests uses synthetic pixels and temporary directories.

Command Bar actions also become selectable in the existing radial menu and Quick Panel. No separate island framework exists in this checkout.

## Temporary link backend contract

Configure an HTTPS base URL and explicitly enable links. No backend is bundled and no network calls run in tests.

POST `{base}/captures` accepts raw `image/png` bytes, at most 25 MiB, with `X-Expiry-Hours: 1`, `6` or `24`. Respond with JSON containing `id`, `url`, `expiresAt` as an ISO 8601 timestamp, and `deleteToken`. The client rejects non-HTTPS links and expiry more than 24 hours plus five minutes into the future.

DELETE `{base}/captures/{id}` receives `Authorization: Bearer {deleteToken}`. Return a 2xx status, or 404 if already deleted. Closing a preview during upload marks the operation abandoned; a subsequently returned link is deleted instead of copied. Live links are stored locally and expired entries are pruned on a timer and on wake.

## Verification boundaries

Do not launch the app during automated verification. Permission prompts, display capture, global shortcut conflicts, pins, scrolling other applications and upload/delete against a real backend require a separate interactive check. This checkout's Command Line Tools require the existing build-script workaround that removes SwiftUI Preview macros from the disposable KeyboardShortcuts dependency checkout.

Window-buffer capture uses a dynamically resolved legacy CoreGraphics entry point with a desktop-independent ScreenCaptureKit fallback. No private cursor-connection property is installed. The overlay uses AppKit cursor rectangles.

Verification: 33 Rust tests and 373 Swift tests passed, including 24 new screenshot tests. Touched Swift files compile without warnings; the existing Rust deployment-target linker warnings and unrelated source deprecation warnings remain. The generated Xcode project passes plutil validation.
