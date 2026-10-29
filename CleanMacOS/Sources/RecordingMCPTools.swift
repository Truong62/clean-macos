import Foundation

enum RecordingMCPTools {
    static let onCamera: Set<String> = ["annotate", "caption", "clear_annotations", "click", "type_text", "press_key", "scroll",
                                        "zoom_in", "zoom_out", "wait", "navigate"]

    static let instructions = """
    Clean macOS records real MP4 demo videos without disturbing the person using this Mac. Nothing of theirs is moved, focused or covered.
    Web apps: start_recording with a url. A hidden browser (no window, separate profile) loads it; captions, annotations, the cursor and \
    click ripples are drawn inside the page and clicks, typing and scrolling go straight into that browser. Coordinates are page CSS pixels, \
    and elements can be targeted by visible text, label or CSS selector. Use navigate to change pages.
    Native apps: start_recording with a window or app records it where it already is, even behind other windows, and acts through \
    Accessibility with a drawn cursor (annotations show over that window). It must not be minimized or in the Stage Manager strip.
    Sign-ins in the hidden browser: by default it keeps sessions from earlier recordings and from sign_in. To show the login itself, \
    start with fresh: true (a signed-out profile), type the test account the person gave you (password fields stay masked) and blur \
    anything sensitive with annotate kind=blur. If you meet a login page without credentials, stop_recording with discard: true, call \
    sign_in so the person signs in themselves, then record again.
    Use background: false only when the person explicitly wants the real screen, mouse and keyboard used.
    Only actions are recorded: the time you spend thinking between tool calls is cut out, so hold_seconds decides how long viewers see each step.
    A good demo: start_recording, screenshot to see the page, annotate kind=title for an intro, then for each step set a caption, \
    point at the control with annotate (circle, arrow, step or spotlight) and hold_seconds of about 1.5, click it, and zoom_in on small details. \
    End with zoom_out, a closing caption, then stop_recording, and check the result with review_recording before handing it over.
    """

    private static let target: [String: Any] = [
        "element": ["type": "string", "description": "Visible text or label of the control to target (button title, link text, placeholder, aria-label)."],
        "selector": ["type": "string", "description": "CSS selector of the element, in hidden browser recordings."],
        "app": ["type": "string", "description": "Native app that owns the element. Defaults to the recorded app."],
        "role": ["type": "string", "description": "Optional role filter such as button, statictext or textfield."],
        "index": ["type": "integer", "description": "Which match to use when several elements share the label. Default 0."],
        "x": ["type": "number", "description": "x in page CSS pixels (hidden browser) or screen points (native), when not using element."],
        "y": ["type": "number", "description": "y in page CSS pixels (hidden browser) or screen points (native), when not using element."],
        "width": ["type": "number"],
        "height": ["type": "number"],
    ]

    private static let hold: [String: Any] = [
        "hold_seconds": ["type": "number", "description": "Pause after the action so viewers can follow."],
    ]

    private static func schema(_ properties: [String: Any]..., required: [String] = []) -> [String: Any] {
        var merged: [String: Any] = [:]
        for part in properties { merged.merge(part) { first, _ in first } }
        return required.isEmpty ? ["type": "object", "properties": merged]
            : ["type": "object", "properties": merged, "required": required]
    }

    static let all: [[String: Any]] = [
        [
            "name": "list_sources",
            "description": "List the displays and on-screen windows that can be recorded, with their screen rectangles. With Stage Manager on, windows in the side strip report thumbnail sizes; start_recording brings the window to the front at full size.",
            "inputSchema": schema(),
        ],
        [
            "name": "start_recording",
            "description": "Start recording a real MP4 video without disturbing the person: give a url to record a web app in a hidden browser, or a window or app to record a native app in place. With background: false it records a real display, or a window brought to the front, using the real mouse. Defaults come from the Clean macOS Screen Record settings.",
            "inputSchema": schema([
                "url": ["type": "string", "description": "Web page to record in a hidden browser, for example http://localhost:3000. It uses its own profile, so log in during the demo if needed. No sound is recorded."],
                "browser": ["type": "string", "enum": ["chrome", "edge", "brave", "chromium"], "description": "Installed browser engine to run hidden. Default chrome."],
                "background": ["type": "boolean", "description": "Record without disturbing the person. Default true."],
                "fresh": ["type": "boolean", "description": "With url: use a brand-new signed-out browser profile, to record a login from the start. Default false keeps saved sign-ins."],
                "window_id": ["type": "integer", "description": "Window id from list_sources."],
                "window": ["type": "string", "description": "Window title or app name to match, for example \"Google Chrome\"."],
                "app": ["type": "string", "description": "App name or bundle id; records every window of that app."],
                "display_id": ["type": "integer", "description": "Display id from list_sources, with background: false."],
                "fps": ["type": "integer", "enum": [24, 30, 60]],
                "resolution": ["type": "string", "enum": ["full", "1080p", "720p"]],
                "system_audio": ["type": "boolean", "description": "Record sound from apps. Default false."],
                "microphone": ["type": "boolean", "description": "Record the microphone. Default false."],
                "show_clicks": ["type": "boolean", "description": "Show a ripple wherever the mouse clicks. Default true."],
                "skip_idle": ["type": "boolean", "description": "Record only while demo tools run (annotate, caption, click, type_text, press_key, scroll, zoom, wait) and cut the time between calls. Default true; set false to record continuously."],
                "max_seconds": ["type": "integer", "description": "Stop automatically after this many seconds. Default 600, max 3600."],
                "folder": ["type": "string", "description": "Folder to save into. Default is the folder set in the app, else Movies."],
                "name": ["type": "string", "description": "File name for the video, for example task-board-demo. Default is Screen Recording with the date."],
            ]),
        ],
        [
            "name": "stop_recording",
            "description": "Stop the recording and return the MP4 path, duration, size and dimensions. With discard: true the take is deleted instead, so you can start over.",
            "inputSchema": schema(["discard": ["type": "boolean", "description": "Delete this take instead of keeping it."]]),
        ],
        [
            "name": "annotate",
            "description": "Draw an annotation that appears in the video: circle, box, arrow, text, step (numbered badge), spotlight (dims everything else), title (full-screen intro card; text lines become title and subtitle) or blur (hides private data such as an email; in the hidden browser, targeting an element blurs the element itself so it stays hidden while it moves). Blurs stay until removed by id.",
            "inputSchema": schema(target, hold, [
                "kind": ["type": "string", "enum": Annotation.Kind.allCases.map(\.rawValue)],
                "text": ["type": "string", "description": "Label shown next to the annotation, or the title card text."],
                "color": ["type": "string", "description": "red (default), orange, yellow, green, blue, purple, pink, white or #RRGGBB."],
                "number": ["type": "integer", "description": "Number for a step badge. Defaults to the next number."],
                "id": ["type": "string", "description": "Name to remove it later with clear_annotations."],
                "seconds": ["type": "number", "description": "Remove it automatically after this many seconds."],
            ], required: ["kind"]),
        ],
        [
            "name": "caption",
            "description": "Show a subtitle over the recorded area. It keeps its size and place in the video while zoomed. Send empty text to hide it.",
            "inputSchema": schema(hold, [
                "text": ["type": "string"],
                "position": ["type": "string", "enum": ["bottom", "top"], "description": "Default bottom; use top when the caption would cover what you show."],
            ]),
        ],
        [
            "name": "clear_annotations",
            "description": "Remove one annotation (or blur) by id, or every annotation except blurs. The caption stays; hide it with caption and empty text.",
            "inputSchema": schema(["id": ["type": "string"]]),
        ],
        [
            "name": "find_element",
            "description": "Find elements by visible text, label or CSS selector and return their rectangles, best match first.",
            "inputSchema": schema(target),
        ],
        [
            "name": "click",
            "description": "Click a control or point with a gliding cursor and a click ripple in the video. In background recordings the real mouse never moves. Annotations are cleared after the click because the screen usually changes; the caption stays.",
            "inputSchema": schema(target, hold, [
                "count": ["type": "integer", "description": "2 for a double click."],
                "keep_annotations": ["type": "boolean", "description": "Keep annotations on screen after the click."],
            ]),
        ],
        [
            "name": "type_text",
            "description": "Type text at a visible typing speed into the focused field, or into the field given by element or selector (it is clicked first).",
            "inputSchema": schema(hold, [
                "text": ["type": "string"],
                "element": ["type": "string", "description": "Label or placeholder of the field to type into."],
                "selector": ["type": "string", "description": "CSS selector of the field, in hidden browser recordings."],
                "app": ["type": "string"],
                "interval": ["type": "number", "description": "Seconds between characters. Default 0.04."],
            ], required: ["text"]),
        ],
        [
            "name": "press_key",
            "description": "Press a key or shortcut such as return, esc, tab, up, cmd+k or cmd+shift+n.",
            "inputSchema": schema(hold, ["keys": ["type": "string"]], required: ["keys"]),
        ],
        [
            "name": "scroll",
            "description": "Smoothly scroll by dy (positive scrolls down), over a control or point if given. With element or selector and no dy, it brings that element to the middle of the view instead. Annotations are cleared because they would no longer line up; the caption stays.",
            "inputSchema": schema(target, hold, [
                "dy": ["type": "number", "description": "Pixels. Default 400."], "dx": ["type": "number"],
                "keep_annotations": ["type": "boolean", "description": "Keep annotations on screen after scrolling."],
            ]),
        ],
        [
            "name": "zoom_in",
            "description": "While recording, smoothly zoom the video into a control or area, like Screen Studio. The screen itself does not change. The video keeps its 16:9 shape, so a wide and short area barely zooms; target a smaller part or pass scale.",
            "inputSchema": schema(target, hold, [
                "scale": ["type": "number", "description": "Zoom factor up to 4. Default fits the target with some margin."],
                "seconds": ["type": "number", "description": "Animation length. Default 0.7."],
            ]),
        ],
        [
            "name": "zoom_out",
            "description": "Smoothly zoom the video back out to the whole recorded area.",
            "inputSchema": schema(hold, ["seconds": ["type": "number", "description": "Animation length. Default 0.7."]]),
        ],
        [
            "name": "wait",
            "description": "Wait a few seconds, for example while an app loads. Max 60.",
            "inputSchema": schema(["seconds": ["type": "number"]]),
        ],
        [
            "name": "sign_in",
            "description": "Open a normal browser window with the hidden browser's profile so the person can sign in to a site themselves. It waits until they close that window (up to seconds, default 300), then later hidden recordings are signed in. Not while a hidden browser recording is running.",
            "inputSchema": schema([
                "url": ["type": "string", "description": "Login page to open."],
                "browser": ["type": "string", "enum": ["chrome", "edge", "brave", "chromium"]],
                "seconds": ["type": "number", "description": "How long to wait for the person, up to 900. Default 300."],
            ], required: ["url"]),
        ],
        [
            "name": "review_recording",
            "description": "Look at a finished video as one image: a grid of evenly spaced frames with their times, to check it before handing it over.",
            "inputSchema": schema([
                "path": ["type": "string", "description": "MP4 to review. Defaults to the last video saved by stop_recording."],
                "frames": ["type": "integer", "description": "How many frames, 4 to 24. Default 12."],
            ]),
        ],
        [
            "name": "navigate",
            "description": "Open another url in the hidden browser recording.",
            "inputSchema": schema(hold, ["url": ["type": "string"]], required: ["url"]),
        ],
        [
            "name": "screenshot",
            "description": "See what is being recorded (the hidden page, or a display) as an image, with the formula to turn image pixels into x and y.",
            "inputSchema": schema(["display_id": ["type": "integer", "description": "Defaults to the recorded display, else the main display."]]),
        ],
    ]
}
