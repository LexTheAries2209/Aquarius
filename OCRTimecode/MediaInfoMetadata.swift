import AVFoundation
import CoreMedia
import Foundation

struct MetadataField: Equatable, Sendable {
    let label: String
    let value: String
}

struct MediaInfoMetadataSnapshot: Equatable, Sendable {
    let fields: [MetadataField]
    let status: String
    let timecodeMetadata: QuickTimeTimecodeMetadata?
}

enum MediaInfoMetadataReader {
    nonisolated static func read(url: URL) async -> MediaInfoMetadataSnapshot {
        await Task.detached(priority: .utility) {
            await readSnapshot(url: url)
        }.value
    }

    nonisolated private static func readSnapshot(url: URL) async -> MediaInfoMetadataSnapshot {
        guard let executableURL = findExecutable() else {
            return MediaInfoMetadataSnapshot(
                fields: [],
                status: "未找到 mediainfo，可安装后读取现有文件元数据",
                timecodeMetadata: nil
            )
        }

        do {
            let data = try runMediaInfo(executableURL: executableURL, mediaURL: url)
            let parsed = try parseFields(from: data, mediaURL: url)
            let timecodeMetadata = merge(
                parsed.timecodeMetadata,
                withFrameQuanta: await QuickTimeTimecodeMetadataReader.readFrameQuanta(url: url)
            )
            return MediaInfoMetadataSnapshot(
                fields: parsed.fields,
                status: parsed.fields.isEmpty ? "mediainfo 未读到可显示元数据" : "已读取 mediainfo 元数据",
                timecodeMetadata: timecodeMetadata
            )
        } catch {
            return MediaInfoMetadataSnapshot(
                fields: [],
                status: "mediainfo 读取失败：\(error.localizedDescription)",
                timecodeMetadata: nil
            )
        }
    }

    nonisolated private static func findExecutable() -> URL? {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/mediainfo" }

        let commonCandidates = [
            "/opt/homebrew/bin/mediainfo",
            "/usr/local/bin/mediainfo",
            "/opt/local/bin/mediainfo"
        ]

        return (pathCandidates + commonCandidates)
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func runMediaInfo(executableURL: URL, mediaURL: URL) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--Output=JSON", mediaURL.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaInfoError.processFailed(message?.isEmpty == false ? message! : "退出码 \(process.terminationStatus)")
        }

        return outputData
    }

    nonisolated private static func parseFields(
        from data: Data,
        mediaURL: URL
    ) throws -> (fields: [MetadataField], timecodeMetadata: QuickTimeTimecodeMetadata?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = root["media"] as? [String: Any],
              let tracks = media["track"] as? [[String: Any]] else {
            throw MediaInfoError.invalidJSON
        }

        let general = firstTrack("General", in: tracks)
        let video = firstTrack("Video", in: tracks)
        let audio = firstTrack("Audio", in: tracks)
        var fields: [MetadataField] = []

        append("文件名", mediaURL.lastPathComponent, to: &fields)
        append("Path", mediaURL.deletingLastPathComponent().path, to: &fields)
        append("Container", joinedValues(from: general, keys: ["Format", "Format_Profile"]), to: &fields)
        append("Video Codec", joinedValues(from: video, keys: ["Format", "Format_Profile"]), to: &fields)
        append("Resolution", resolution(from: video), to: &fields)
        append("Frame Rate", frameRate(from: video) ?? frameRate(from: general), to: &fields)
        append("Duration", duration(from: general) ?? duration(from: video), to: &fields)
        append("Frame Count", value(from: video, keys: ["FrameCount"]) ?? value(from: general, keys: ["FrameCount"]), to: &fields)
        append("当前起始时间码", firstValue(in: tracks, keys: ["TimeCode_FirstFrame", "TimeCode_FirstFrame/String"]), to: &fields)
        append("当前结束时间码", firstValue(in: tracks, keys: ["TimeCode_LastFrame", "TimeCode_LastFrame/String"]), to: &fields)
        append("Audio", audioSummary(from: audio), to: &fields)

        return (fields, quickTimeTimecodeMetadata(from: tracks))
    }

    nonisolated private static func firstTrack(_ type: String, in tracks: [[String: Any]]) -> [String: Any]? {
        tracks.first { value(from: $0, keys: ["@type"]) == type }
    }

    nonisolated private static func append(_ label: String, _ value: String?, to fields: inout [MetadataField]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        fields.append(MetadataField(label: label, value: value))
    }

    nonisolated private static func firstValue(in tracks: [[String: Any]], keys: [String]) -> String? {
        for track in tracks {
            if let value = value(from: track, keys: keys) {
                return value
            }
        }
        return nil
    }

    nonisolated private static func quickTimeTimecodeMetadata(from tracks: [[String: Any]]) -> QuickTimeTimecodeMetadata? {
        guard let track = tracks.first(where: { track in
            let type = value(from: track, keys: ["Type"])?.lowercased() ?? ""
            let format = value(from: track, keys: ["Format"])?.lowercased() ?? ""
            return type.contains("time code") || format.contains("quicktime tc")
        }) else {
            return nil
        }

        let frameRate = value(from: track, keys: ["FrameRate"]).flatMap(Double.init)
        return QuickTimeTimecodeMetadata(
            firstFrame: value(from: track, keys: ["TimeCode_FirstFrame", "TimeCode_FirstFrame/String"]),
            lastFrame: value(from: track, keys: ["TimeCode_LastFrame", "TimeCode_LastFrame/String"]),
            frameRate: frameRate,
            frameQuanta: nil,
            format: value(from: track, keys: ["Format"])
        )
    }

    nonisolated private static func merge(
        _ metadata: QuickTimeTimecodeMetadata?,
        withFrameQuanta frameQuanta: Int?
    ) -> QuickTimeTimecodeMetadata? {
        guard metadata != nil || frameQuanta != nil else {
            return nil
        }

        return QuickTimeTimecodeMetadata(
            firstFrame: metadata?.firstFrame,
            lastFrame: metadata?.lastFrame,
            frameRate: metadata?.frameRate,
            frameQuanta: frameQuanta ?? metadata?.frameQuanta,
            format: metadata?.format
        )
    }

    nonisolated private static func value(from track: [String: Any]?, keys: [String]) -> String? {
        guard let track else {
            return nil
        }

        for key in keys {
            guard let rawValue = track[key] else {
                continue
            }

            if let string = rawValue as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            } else if let number = rawValue as? NSNumber {
                return number.stringValue
            }
        }

        return nil
    }

    nonisolated private static func joinedValues(from track: [String: Any]?, keys: [String]) -> String? {
        let values = keys.compactMap { value(from: track, keys: [$0]) }
        guard !values.isEmpty else {
            return nil
        }
        return values.joined(separator: " / ")
    }

    nonisolated private static func resolution(from track: [String: Any]?) -> String? {
        guard let width = value(from: track, keys: ["Width"]),
              let height = value(from: track, keys: ["Height"]) else {
            return nil
        }
        return "\(width) x \(height)"
    }

    nonisolated private static func frameRate(from track: [String: Any]?) -> String? {
        guard let frameRate = value(from: track, keys: ["FrameRate"]) else {
            return nil
        }

        if let number = Double(frameRate) {
            return String(format: "%.3f fps", number)
        }
        return frameRate
    }

    nonisolated private static func duration(from track: [String: Any]?) -> String? {
        if let formatted = value(from: track, keys: ["Duration/String3", "Duration/String2", "Duration/String"]) {
            return formatted
        }

        guard let rawDuration = value(from: track, keys: ["Duration"]),
              let number = Double(rawDuration) else {
            return nil
        }

        let seconds = number > 1000 ? number / 1000 : number
        return String(format: "%.3fs", seconds)
    }

    nonisolated private static func audioSummary(from track: [String: Any]?) -> String? {
        guard let track else {
            return nil
        }

        let format = value(from: track, keys: ["Format"])
        let channels = value(from: track, keys: ["Channels"])
        let sampleRate = value(from: track, keys: ["SamplingRate"]).flatMap { rawValue -> String? in
            guard let number = Double(rawValue) else {
                return rawValue
            }
            return String(format: "%.0f Hz", number)
        }

        let parts = [format, channels.map { "\($0) ch" }, sampleRate].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private enum MediaInfoError: LocalizedError {
        case invalidJSON
        case processFailed(String)

        nonisolated var errorDescription: String? {
            switch self {
            case .invalidJSON:
                "无法解析 mediainfo JSON"
            case .processFailed(let message):
                message
            }
        }
    }
}

private enum QuickTimeTimecodeMetadataReader {
    nonisolated static func readFrameQuanta(url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let description = try? await track.load(.formatDescriptions).first else {
            return nil
        }

        let frameQuanta = CMTimeCodeFormatDescriptionGetFrameQuanta(description)
        guard frameQuanta > 0 else {
            return nil
        }
        return Int(frameQuanta)
    }
}
