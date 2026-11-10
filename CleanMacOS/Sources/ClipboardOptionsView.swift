import KeyboardShortcuts
import SwiftUI

struct ClipboardOptionsView: View {
    @EnvironmentObject var clipboard: ClipboardViewModel
    private let delays = [5, 10, 20, 30, 60, 120, 300, 600, 1800, 3600]

    var body: some View {
        VStack(spacing: 16) {
            CardSection(title: "What to keep", icon: "tray.and.arrow.down") {
                Toggle("Also save copied images and files", isOn: $clipboard.options.savesImagesAndFiles)
                Picker("Keep items for", selection: $clipboard.options.retentionDays) {
                    ForEach(ClipboardOptions.retentionChoices, id: \.self) { Text(Self.retentionTitle($0)).tag($0) }
                }
                .frame(maxWidth: 320)
                Text("Pinned items are never removed.").font(.caption).foregroundStyle(.secondary)
            }
            CardSection(title: "Display", icon: "eye") {
                Toggle("Show the app each item was copied from", isOn: $clipboard.options.showsSourceIcons)
                Toggle("Show recent items in the menu bar panel", isOn: $clipboard.options.showsInMenuPanel)
                Toggle("Show the latest copy in the menu bar", isOn: $clipboard.options.showsLatestInMenuBar)
                if clipboard.options.showsLatestInMenuBar {
                    Stepper(value: $clipboard.options.latestLength, in: 5...50) {
                        Text("Up to \(clipboard.options.latestLength) characters")
                    }
                }
            }
            CardSection(title: "Privacy", icon: "hand.raised") {
                Toggle("Skip text that looks like a password, key or token", isOn: $clipboard.options.skipsSensitiveText)
                AppListEditor(title: "Never save copies from these apps", bundleIDs: $clipboard.options.skippedApps)
            }
            CardSection(title: "Links", icon: "link") {
                Toggle("Remove tracking from links as you copy them", isOn: $clipboard.options.cleansURLs)
                NameListField(title: "Also remove", prompt: "ref, source", names: $clipboard.options.urlRules.extraNames)
                NameListField(title: "Never remove", prompt: "utm_source", names: $clipboard.options.urlRules.keptNames)
                Text("Removes utm_ tags, click IDs such as fbclid and gclid, and share tags on YouTube, X, Instagram, Spotify, Reddit and TikTok.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CardSection(title: "Empty the clipboard", icon: "clock.arrow.circlepath") {
                HStack {
                    Toggle("After", isOn: $clipboard.options.autoClear.afterDelay)
                    Picker("", selection: $clipboard.options.autoClear.delaySeconds) {
                        ForEach(delays, id: \.self) { Text(Self.delayTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(!clipboard.options.autoClear.afterDelay)
                    Text("without a new copy")
                }
                Toggle("When the Mac goes to sleep", isOn: $clipboard.options.autoClear.onSleep)
                Toggle("When the display sleeps", isOn: $clipboard.options.autoClear.onDisplaySleep)
                Toggle("When the screen locks", isOn: $clipboard.options.autoClear.onLock)
                Text("This empties what is on the clipboard now. Your history stays.").font(.caption).foregroundStyle(.secondary)
            }
            CardSection(title: "Paste as plain text", icon: "textformat") {
                Toggle("Paste without formatting using a shortcut", isOn: $clipboard.options.pastesPlainText)
                if clipboard.options.pastesPlainText {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .pastePlainText)
                    }
                }
            }
        }
    }

    static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: "Forever"
        case 1: "1 day"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    static func delayTitle(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
    }
}

struct NameListField: View {
    let title: String
    let prompt: String
    @Binding var names: [String]
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = names.joined(separator: ", ") }
                .onChange(of: text) { _, value in
                    names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
        }
    }
}

struct LinkCleanerField: View {
    @EnvironmentObject var clipboard: ClipboardViewModel
    @State private var link = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clean a link").font(.headline)
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(clean)
            HStack {
                Button("Paste") {
                    link = NSPasteboard.general.string(forType: .string) ?? ""
                    clean()
                }
                Button("Clean", action: clean).disabled(link.isEmpty)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
                .disabled(link.isEmpty)
                Button("Clear") {
                    link = ""
                    message = ""
                }
                .disabled(link.isEmpty)
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).frame(width: 360, alignment: .leading)
            }
        }
        .padding(16)
    }

    private func clean() {
        guard let result = URLCleaner.clean(link, rules: clipboard.options.urlRules) else {
            message = "Paste a valid web link."
            return
        }
        link = result.url
        message = result.removed.isEmpty ? "Nothing to clean." : "Removed " + result.removed.joined(separator: ", ") + "."
    }
}
