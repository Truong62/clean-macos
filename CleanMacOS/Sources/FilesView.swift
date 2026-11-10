import KeyboardShortcuts
import SwiftUI

struct FilesView: View {
    @EnvironmentObject var finder: FinderTools
    @EnvironmentObject var diskImages: DiskImageWatcher
    @EnvironmentObject var shelf: ShelfController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "folder.fill.badge.gearshape", title: "Finder Tools",
                           subtitle: "Cut and paste files, rename with one key, keep things on a Shelf and install apps from disk images.",
                           colors: [.cyan, .blue])
                if !AXIsProcessTrusted() {
                    Label("These tools need Accessibility access for \(AppIdentity.installedName).", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .glassCard(cornerRadius: 18)
                }
                CardSection(title: "Cut and paste", icon: "scissors") {
                    Toggle("⌘X then ⌘V moves files in Finder", isOn: $finder.settings.cutsAndPastes)
                    Toggle("Show progress for moves between volumes", isOn: $finder.settings.showsTransferProgress)
                        .disabled(!finder.settings.cutsAndPastes)
                    Toggle("Show a message when files are cut and moved", isOn: $finder.settings.showsHUD)
                        .disabled(!finder.settings.cutsAndPastes)
                    if !finder.cutItems.isEmpty {
                        HStack {
                            Label("\(finder.cutItems.count) \(finder.cutItems.count == 1 ? "item" : "items") cut, waiting for ⌘V", systemImage: "scissors")
                            Spacer()
                            Button("Cancel") { finder.cancelCut() }
                        }
                    }
                    Text("Select files in Finder, press ⌘X, open another folder and press ⌘V. ⌘C or copying anything else cancels. Names that already exist get a number. The first time, macOS asks to let MacKit control Finder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Rename with one key", icon: "character.cursor.ibeam") {
                    Toggle("Rename the selected item in Finder", isOn: $finder.settings.renames)
                    HStack {
                        Text("Key")
                        Spacer()
                        KeyCaptureButton(key: $finder.settings.renameKey, defaultKey: .f2)
                    }
                    .disabled(!finder.settings.renames)
                }
                CardSection(title: "Shelf", icon: "tray.full") {
                    Toggle("Turn on the Shelf, a place to park files, images, links and text", isOn: $shelf.settings.isEnabled)
                    Group {
                        HStack {
                            Text("Shortcut")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .toggleShelf)
                        }
                        Toggle("The shortcut also adds what is selected in Finder", isOn: $shelf.settings.addsFinderSelection)
                        Toggle("Peek at a screen edge while dragging", isOn: $shelf.settings.peeksAtEdges)
                        Toggle("Group drops into piles", isOn: $shelf.settings.groupsDrops)
                        Toggle("Shake while dragging to open it", isOn: $shelf.settings.opensOnShake)
                        Toggle("Show a drop zone at the top of the screen while dragging", isOn: $shelf.settings.showsDropZone)
                        Toggle("Close the Shelf after dragging items out", isOn: $shelf.settings.closesAfterDrop)
                        Toggle("Remove items once you drag them out", isOn: $shelf.settings.removesAfterDragOut)
                        Toggle("Empty the Shelf when you close it", isOn: $shelf.settings.clearsOnClose)
                        AppListEditor(title: "Don't open it automatically while using", bundleIDs: $shelf.settings.excludedApps)
                        HStack {
                            Text("\(shelf.items.count) \(shelf.items.count == 1 ? "item" : "items") on the Shelf").foregroundStyle(.secondary)
                            Spacer()
                            Button("Open the Shelf") { shelf.open() }
                        }
                    }
                    .disabled(!shelf.settings.isEnabled)
                }
                CardSection(title: "Install from disk images", icon: "externaldrive.badge.plus") {
                    Toggle("Offer to install the app when you open a disk image", isOn: $diskImages.settings.offersInstall)
                    Group {
                        Toggle("Move the disk image to the Trash afterwards", isOn: $diskImages.settings.trashesImage)
                        Toggle("Show the app in Finder", isOn: $diskImages.settings.revealsApp)
                        Toggle("Install in my own Applications folder", isOn: $diskImages.settings.usesHomeApplications)
                    }
                    .disabled(!diskImages.settings.offersInstall)
                    Text("Works for a downloaded .dmg with one app inside. The app is checked with Gatekeeper, copied in, and the disk image is ejected. Apps you already have are never replaced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Paste images as files", icon: "photo.on.rectangle") {
                    Toggle("⌘V in Finder saves a copied image as a PNG file", isOn: $finder.settings.pastesImages)
                    Text("Files are named like \(PastedImage.fileName(at: Date())). ⇧⌘V and copied files paste as usual.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct KeyCaptureButton: View {
    static let escapeKey: UInt16 = 53

    @Binding var key: RenameKey
    let defaultKey: RenameKey
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(monitor == nil ? key.title : "Press a key…") {
                if monitor == nil { start() } else { stop() }
            }
            .frame(minWidth: 110)
            Button("Reset") { key = defaultKey }.disabled(key == defaultKey)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != Self.escapeKey {
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(RenameKey.relevant)
                key = RenameKey(keyCode: Int(event.keyCode), modifiers: flags.rawValue)
            }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
