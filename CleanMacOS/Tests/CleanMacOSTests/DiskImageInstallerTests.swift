import Foundation
import Testing
@testable import CleanMacOS

struct DiskImageInstallerTests {
    private func info(_ images: [(path: String, mounts: [String])]) -> Data {
        let list = images.map { image in
            ["image-path": image.path,
             "system-entities": [["dev-entry": "/dev/disk9"]] + image.mounts.map { ["dev-entry": "/dev/disk9s1", "mount-point": $0] }] as [String: Any]
        }
        return try! PropertyListSerialization.data(fromPropertyList: ["images": list], format: .xml, options: 0)
    }

    @Test func findsTheDiskImageBehindAVolume() {
        let data = info([("/Users/me/Downloads/Foo.dmg", ["/Volumes/Foo"]), ("/Users/me/Bar.dmg", ["/Volumes/Bar"])])
        #expect(DiskImageInfo.imagePath(mountedAt: "/Volumes/Foo", in: data) == "/Users/me/Downloads/Foo.dmg")
        #expect(DiskImageInfo.imagePath(mountedAt: "/Volumes/Other", in: data) == nil)
        let twice = info([("/a.dmg", ["/Volumes/Foo"]), ("/b.dmg", ["/Volumes/Foo"])])
        #expect(DiskImageInfo.imagePath(mountedAt: "/Volumes/Foo", in: twice) == nil)
        #expect(DiskImageInfo.imagePath(mountedAt: "/Volumes/Foo", in: Data("junk".utf8)) == nil)
    }

    @Test func offersOnlyASingleAppFromARealDownload() {
        let entries = [VolumeEntry(name: "Foo.app", isLink: false), VolumeEntry(name: "Applications", isLink: true), VolumeEntry(name: ".background", isLink: false)]
        #expect(InstallPlan.appName(in: entries) == "Foo.app")
        #expect(InstallPlan.appName(in: entries + [VolumeEntry(name: "Bar.app", isLink: false)]) == nil)
        #expect(InstallPlan.appName(in: [VolumeEntry(name: "Foo.app", isLink: true)]) == nil)
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(InstallPlan.isDownloadedImage("/Users/me/Downloads/Foo.dmg", home: home))
        #expect(!InstallPlan.isDownloadedImage("/Users/me/Downloads/Foo.sparseimage", home: home))
        #expect(!InstallPlan.isDownloadedImage("/Users/me/Library/Caches/Homebrew/downloads/abc--Foo.dmg", home: home))
    }

    @Test func installsThroughAStagingFolderAndNeverReplaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let volume = root.appendingPathComponent("Volume")
        let target = root.appendingPathComponent("Applications")
        let app = volume.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Foo"))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        #expect(DiskImageInstaller.install(app, into: target) { _ in false } == .unverified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

        #expect(DiskImageInstaller.install(app, into: target) { _ in true } == .installed(target.appendingPathComponent("Foo.app", isDirectory: true)))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Foo.app/Contents/MacOS/Foo").path))
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(DiskImageInstaller.install(app, into: target) { _ in true } == .alreadyInstalled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["Foo.app"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func describesWhatHappened() {
        #expect(InstallOutcome(installed: true, ejected: true, trashed: true).message(app: "Foo") == "Installed Foo")
        #expect(InstallOutcome(installed: true, ejected: false, trashed: false).message(app: "Foo") == "Installed Foo · couldn't eject the disk image")
        #expect(InstallOutcome(installed: true, ejected: true, trashed: false, wantedTrash: true).message(app: "Foo") == "Installed Foo · couldn't move the disk image to the Trash")
        #expect(InstallOutcome(installed: true, ejected: true, trashed: false, wantedTrash: false).message(app: "Foo") == "Installed Foo")
    }
}
