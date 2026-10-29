import Foundation

enum RecordingMCPTools {
    static let onCamera: Set<String> = ["annotate", "caption", "clear_annotations", "click", "type_text", "press_key", "scroll",
                                        "zoom_in", "zoom_out", "wait"]

    static let instructions = """
    Clean macOS records real MP4 screen videos and helps you direct a polished demo.
    By default only the actions are recorded: the time you spend thinking between tool calls is cut out, so hold_seconds decides how long viewers see each step.
    Coordinates are macOS screen points with the origin at the top-left of the main display (the same as list_sources and screenshot).
    A good demo: screenshot to see the screen, start_recording, annotate kind=title for an intro, then for each step set a caption, \
    point at the control with annotate (circle, arrow, step or spotlight) and hold_seconds of about 1.5, click it, \
    clear_annotations, and zoom_in on details that are small. End with zoom_out, a closing caption, then stop_recording.
    Prefer targeting controls by element label with the app name; use x and y from a screenshot when labels are missing.
    """

    private static let target: [String: Any] = [
        "element": ["type": "string", "description": "Label of a control to target (button title, text, description), found with Accessibility."],
        "app": ["type": "string", "description": "App that owns the element. Defaults to the recorded app, else the frontmost app."],
        "role": ["type": "string", "description": "Optional role filter such as button, statictext or textfield."],
        "index": ["type": "integer", "description": "Which match to use when several elements share the label. Default 0."],
        "x": ["type": "number", "description": "Screen x in points when not using element."],
        "y": ["type": "number", "description": "Screen y in points when not using element."],
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
            "description": "Start recording a real MP4 video of a window, an app or a display. Pick at most one of window_id, window, app or display_id; with none, the main display is recorded. A window or app target is brought to the front first, and a window is recorded as its area of the screen so menus, popups and annotations appear. Defaults come from the Clean macOS Screen Record settings.",
            "inputSchema": schema([
                "window_id": ["type": "integer", "description": "Window id from list_sources."],
                "window": ["type": "string", "description": "Window title or app name to match, for example \"Google Chrome\"."],
                "app": ["type": "string", "description": "App name or bundle id; records every window of that app."],
                "display_id": ["type": "integer", "description": "Display id from list_sources."],
                "fps": ["type": "integer", "enum": [24, 30, 60]],
                "resolution": ["type": "string", "enum": ["full", "1080p", "720p"]],
                "system_audio": ["type": "boolean", "description": "Record sound from apps. Default false."],
                "microphone": ["type": "boolean", "description": "Record the microphone. Default false."],
                "show_clicks": ["type": "boolean", "description": "Show a ripple wherever the mouse clicks. Default true."],
                "skip_idle": ["type": "boolean", "description": "Record only while demo tools run (annotate, caption, click, type_text, press_key, scroll, zoom, wait) and cut the time between calls. Default true; set false to record continuously."],
                "max_seconds": ["type": "integer", "description": "Stop automatically after this many seconds. Default 600, max 3600."],
                "folder": ["type": "string", "description": "Folder to save into. Default is the folder set in the app, else Movies."],
            ]),
        ],
        [
            "name": "stop_recording",
            "description": "Stop the recording and return the MP4 path, duration, size and dimensions.",
            "inputSchema": schema(),
        ],
        [
            "name": "annotate",
            "description": "Draw an annotation on screen that appears in the video: circle, box, arrow, text, step (numbered badge), spotlight (dims everything else) or title (full-screen intro card; text lines become title and subtitle).",
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
            "description": "Remove one annotation by id, or every annotation. The caption stays; hide it with caption and empty text.",
            "inputSchema": schema(["id": ["type": "string"]]),
        ],
        [
            "name": "find_element",
            "description": "Find controls by label in an app and return their screen rectangles.",
            "inputSchema": schema(target, required: ["element"]),
        ],
        [
            "name": "click",
            "description": "Glide the mouse to a control or point and click it, with a click ripple in the video. Annotations are cleared after the click because the screen usually changes; the caption stays.",
            "inputSchema": schema(target, hold, [
                "count": ["type": "integer", "description": "2 for a double click."],
                "keep_annotations": ["type": "boolean", "description": "Keep annotations on screen after the click."],
            ]),
        ],
        [
            "name": "type_text",
            "description": "Type text into the focused field at a visible typing speed.",
            "inputSchema": schema(hold, [
                "text": ["type": "string"],
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
            "description": "Smoothly scroll, optionally over a control or point first. Positive dy scrolls down.",
            "inputSchema": schema(target, hold, ["dy": ["type": "number", "description": "Pixels. Default 400."], "dx": ["type": "number"]]),
        ],
        [
            "name": "zoom_in",
            "description": "While recording, smoothly zoom the video into a control or area, like Screen Studio. The screen itself does not change.",
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
            "name": "screenshot",
            "description": "See a display as an image, with the formula to turn image pixels into screen points for x and y.",
            "inputSchema": schema(["display_id": ["type": "integer", "description": "Defaults to the recorded display, else the main display."]]),
        ],
    ]
}
