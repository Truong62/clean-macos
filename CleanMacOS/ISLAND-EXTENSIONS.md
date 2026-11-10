# Island extensions

This implementation covers a substantial subset of the requested extensions. It does not complete the entire behavior specification.

Implemented:

- Lyrics panel with session-only LRC imports capped at 128 KiB, optional LRCLIB lookup and MusicBrainz aliases, title/duration matching and ranking, bounded responses, ephemeral cookie-free sessions, refused redirects, request cancellation, result caches, timed line boundaries, per-song offsets, and Escape handling. Online lookup is off by default.
- Mutually exclusive lyrics and MacKit-player queue panels. The MacKit queue supports jumping to an upcoming item. External player transport commands are available through MediaRemote.
- Optional live bars with a private, unmuted process tap, attributed player helpers, 1024-sample Hann-windowed FFT, seven logarithmic bands, asymmetric smoothing, synthetic fallback, pause teardown, output/player changes, and suspension. Enabling the toggle in the current session arms permission requests; persisted enablement alone does not prompt at launch.
- Screen Watch through the existing screenshot selector, fingerprint-gated Vision OCR, changes/settles/contains/reaches rules, locale-aware number parsing, selectable headlines, followed-window capture, fixed-display capture excluding MacKit windows, notifications on explicit start, completion notices, and re-arming.
- Claude Code and Codex turn events through AIUsageMonitor, ten-minute inactivity expiry, elapsed/token/estimated-cost/limit readings, completion notices, limit threshold/renewal notices, and limits cards with pace and stale-state presentation. Log scans are bounded to 64 recent files per provider and the latest 2 MiB of each file; turns whose start is outside that tail are omitted.
- Accessory connection baselines, paired-device filtering, silent disconnect tracking, bounded expiring notices, and fresh HID battery readings through SystemMonitor with hysteresis.
- Axis-locked gestures, momentum restrictions, modifier/menu/capture/shelf-drag suppression, and skip nudge feedback.
- Embedded camera shortcut routing and permission grace. Existing scratchpad, battery power-source notifications, and display-copy behavior are retained.
- Shelf sharing/AirDrop, removal and confirmed clearing, per-item ZIP export with destination validation and cancellation, and media optimization on the right side of the drop target using Media Tools.
- Optional music volume row, MacKit shuffle/output controls, new-track and microphone notices, Keep Awake remaining time, capture controls and 12-second previews, up to three shortcut buttons per side, and an optional Screen Watch global shortcut and Command Bar action.
- Backward-compatible decoding for every Island setting. New switches and shortcut lists default to off/empty.

Not implemented or incomplete:

- External MediaRemote queue helper, queue notifications, artwork requests, command-capability checks, and three-read play-item verification. Queue rows currently use symbols rather than artwork.
- Lock-screen artwork, animated notched-display bars, exact clock/login positioning, and retaining calendar/download details during suspension. A non-key private-Space scene and transport controls are implemented, gated by symbol availability; lock-screen rendering is unverified.
- OpenCode and Copilot adapters, daily budget notices, resting limit ring, and the specified agent wing sizing/icons.
- Watching windows across other Spaces. Off-screen windows pause conservatively because the capture metadata does not distinguish minimization from other Spaces without additional integration.
- Bluetooth profiler/BLE battery sources and accessory-specific notice icons.
- External-player shuffle dictionary probing, preferred-player selection, and playback-source selection. Shared menu-bar/Island battery warning colors and keyboard-light/input-source notices are implemented.
- The exact specified wing layouts, screen-watch thumbnail mode, and lock/unlock animation choreography.

Validation is automated only. No app launch, visible-window manipulation, permission prompts, audio playback, or system-setting changes were performed. Live process taps, camera, Screen Recording/OCR, Bluetooth events, lock-screen behavior, external-player commands, and display placement still need interactive testing. This Mac mini has no internal battery or built-in notched display. Existing unrelated Swift deprecation warnings and Rust static-library deployment-target linker warnings remain; modified Swift sources produced no warnings in verification.
