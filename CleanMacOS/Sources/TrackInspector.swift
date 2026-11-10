import AVFoundation
import AudioToolbox
import Foundation

struct InspectedTrack: Sendable {
    var tags: TrackTags
    var format: TrackFormat
    var duration: Double
}

enum TrackInspectionError: Error, Equatable {
    case lossy(String)
    case unsupported(String)
    case unreadable
    case compressedDSD
}

enum TrackInspector {
    static let pcmExtensions: Set<String> = ["flac", "m4a", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf"]
    static let lossyExtensions: [String: String] = [
        "mp3": "MP3", "mp2": "MP2", "aac": "AAC", "ogg": "Ogg Vorbis", "oga": "Ogg Vorbis", "opus": "Opus",
        "wma": "WMA", "m4b": "AAC", "ac3": "AC-3", "amr": "AMR",
    ]
    private static let losslessCodecs: [AudioFormatID: String] = [kAudioFormatFLAC: "FLAC", kAudioFormatAppleLossless: "ALAC"]
    private static let lossyCodecs: [AudioFormatID: String] = [
        kAudioFormatMPEG4AAC: "AAC", kAudioFormatMPEG4AAC_HE: "AAC", kAudioFormatMPEG4AAC_HE_V2: "AAC",
        kAudioFormatMPEGLayer3: "MP3", kAudioFormatOpus: "Opus", kAudioFormatAC3: "AC-3",
    ]

    static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return pcmExtensions.contains(ext) || DSDFile.extensions.contains(ext) || lossyExtensions[ext] != nil
    }

    static func inspect(_ url: URL) async throws -> InspectedTrack {
        let ext = url.pathExtension.lowercased()
        if let codec = lossyExtensions[ext] { throw TrackInspectionError.lossy(codec) }
        if DSDFile.extensions.contains(ext) { return try inspectDSD(url) }
        guard pcmExtensions.contains(ext) else { throw TrackInspectionError.unsupported(ext) }
        let format = try pcmFormat(url)
        guard let file = try? AVAudioFile(forReading: url) else { throw TrackInspectionError.unreadable }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return InspectedTrack(tags: await tags(url), format: format, duration: duration)
    }

    private static func inspectDSD(_ url: URL) throws -> InspectedTrack {
        do {
            let info = try DSDFile.info(url: url)
            let format = TrackFormat(codec: url.pathExtension.uppercased(), sampleRate: Double(info.sampleRate), bitDepth: 1, channels: info.channels)
            return InspectedTrack(tags: DSDFile.tags(url: url, info: info) ?? TrackTags(), format: format, duration: info.duration)
        } catch DSDFileError.compressed {
            throw TrackInspectionError.compressedDSD
        } catch {
            throw TrackInspectionError.unreadable
        }
    }

    private static func pcmFormat(_ url: URL) throws -> TrackFormat {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { throw TrackInspectionError.unreadable }
        defer { AudioFileClose(fileID) }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &description) == noErr else { throw TrackInspectionError.unreadable }
        if let codec = lossyCodecs[description.mFormatID] { throw TrackInspectionError.lossy(codec) }
        let codec: String
        if let lossless = losslessCodecs[description.mFormatID] {
            codec = lossless
        } else if description.mFormatID == kAudioFormatLinearPCM {
            codec = pcmContainerName(url.pathExtension.lowercased())
        } else {
            throw TrackInspectionError.lossy(fourCharacterCode(description.mFormatID))
        }
        var sourceDepth: Int32 = 0
        var depthSize = UInt32(MemoryLayout<Int32>.size)
        AudioFileGetProperty(fileID, kAudioFilePropertySourceBitDepth, &depthSize, &sourceDepth)
        let depth = sourceDepth != 0 ? Int(abs(sourceDepth)) : Int(description.mBitsPerChannel)
        guard depth > 0 else { throw TrackInspectionError.unreadable }
        return TrackFormat(codec: codec, sampleRate: description.mSampleRate, bitDepth: depth, channels: Int(description.mChannelsPerFrame))
    }

    private static func pcmContainerName(_ ext: String) -> String {
        switch ext {
        case "wav", "wave": "WAV"
        case "aif", "aiff", "aifc": "AIFF"
        default: ext.uppercased()
        }
    }

    private static func fourCharacterCode(_ code: AudioFormatID) -> String {
        let bytes = withUnsafeBytes(of: code.bigEndian, Array.init)
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private static func tags(_ url: URL) async -> TrackTags {
        guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return TrackTags() }
        var entries: [TrackTags.MetadataEntry] = []
        for item in items {
            guard let identifier = item.identifier?.rawValue, let value = try? await item.load(.value) else { continue }
            entries.append(.init(commonKey: item.commonKey?.rawValue, identifier: identifier, value: value))
        }
        return TrackTags(metadata: entries)
    }
}

extension TrackTags {
    struct MetadataEntry {
        let commonKey: String?
        let identifier: String
        let value: Any
    }

    private static let commonKeys: [String: WritableKeyPath<TrackTags, String?>] = ["title": \.title, "artist": \.artist, "albumName": \.album]
    private static let textKeys: [String: WritableKeyPath<TrackTags, String?>] = [
        "TITLE": \.title, "©NAM": \.title, "TIT2": \.title,
        "ARTIST": \.artist, "©ART": \.artist, "TPE1": \.artist,
        "ALBUM": \.album, "©ALB": \.album, "TALB": \.album,
        "ALBUMARTIST": \.albumArtist, "ALBUM ARTIST": \.albumArtist, "AART": \.albumArtist, "TPE2": \.albumArtist,
        "GENRE": \.genre, "©GEN": \.genre, "TCON": \.genre,
    ]
    private static let trackKeys: Set<String> = ["TRACKNUMBER", "TRACK NUMBER", "TRKN", "TRCK"]
    private static let discKeys: Set<String> = ["DISCNUMBER", "DISC NUMBER", "DISK", "TPOS"]
    private static let yearKeys: Set<String> = ["DATE", "YEAR", "©DAY", "TDRC", "TYER", "RECORDED DATE"]

    init(metadata: [MetadataEntry]) {
        self.init()
        for entry in metadata {
            let key = Self.normalizedKey(entry.identifier)
            let text = Self.text(entry.value)
            if entry.commonKey == "artwork" || key == "METADATA_BLOCK_PICTURE" || key == "COVR" || key == "APIC" {
                if artwork == nil { artwork = entry.value as? Data }
            } else if let path = entry.commonKey.flatMap({ Self.commonKeys[$0] }) ?? Self.textKeys[key] {
                if self[keyPath: path] == nil { self[keyPath: path] = text }
            } else if Self.trackKeys.contains(key) {
                trackNumber = trackNumber ?? Self.number(entry.value)
            } else if Self.discKeys.contains(key) {
                discNumber = discNumber ?? Self.number(entry.value)
            } else if entry.commonKey == "creationDate" || Self.yearKeys.contains(key) {
                year = year ?? Self.year(text)
            }
        }
    }

    private static func normalizedKey(_ identifier: String) -> String {
        let raw = identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
        let decoded = raw.replacingOccurrences(of: "%A9", with: "©").removingPercentEncoding ?? raw
        let trimmed = decoded.hasPrefix("info-") ? String(decoded.dropFirst(5)) : decoded
        return trimmed.uppercased()
    }

    private static func text(_ value: Any) -> String? {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func number(_ value: Any) -> Int? {
        if let data = value as? Data, data.count >= 4 { return Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3]) }
        if let number = value as? NSNumber { return number.intValue }
        return leadingNumber(text(value))
    }
}
