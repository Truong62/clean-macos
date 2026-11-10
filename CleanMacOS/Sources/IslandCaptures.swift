import SwiftUI

struct IslandCaptureView: View {
    @ObservedObject var capture: ScreenshotController
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var island: IslandController
    @State private var paused = false
    var body: some View {
        VStack(spacing: 12) {
            if recorder.isRecording {
                Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
                HStack {
                    Button(paused ? "Resume" : "Pause") {
                        if paused { recorder.resumeCapture() } else { recorder.pauseCapture() }
                        paused.toggle()
                    }
                    Button("Stop Recording") { Task { await recorder.stop() } }
                }
            } else {
                HStack {
                    Button("Capture Area") { island.close(); capture.start() }
                    Button("Capture Display") { island.close(); capture.start(displayOnly: true) }
                    Button("Grab Text") { island.close(); capture.start(.text) }
                }
                Button("Choose Recording Area") { island.close(); capture.start(.recording) }.disabled(!ScreenRecorder.isSupported)
            }
            if let image = island.capturePreview {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 130)
            }
            Text(capture.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
