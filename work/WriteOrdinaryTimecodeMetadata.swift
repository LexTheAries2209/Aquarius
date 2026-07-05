// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Foundation

enum OrdinaryMetadataError: Error {
    case missingArgument
    case noTracksToCopy
    case exportSessionUnavailable
    case exportFailed(String)
}

func quickTimeItem(key: String, value: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = key as NSString
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

func commonItem(identifier: AVMetadataIdentifier, value: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

guard CommandLine.arguments.count == 4 else {
    print("Usage: WriteOrdinaryTimecodeMetadata <input.mov> <output.mov> <timecode>")
    throw OrdinaryMetadataError.missingArgument
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let timecode = CommandLine.arguments[3]
let asset = AVURLAsset(url: inputURL)
let composition = AVMutableComposition()
let fullRange = CMTimeRange(start: .zero, duration: asset.duration)
var copiedTrackCount = 0

for mediaType in [AVMediaType.video, .audio] {
    for sourceTrack in asset.tracks(withMediaType: mediaType) {
        guard let targetTrack = composition.addMutableTrack(
            withMediaType: mediaType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            continue
        }
        try targetTrack.insertTimeRange(fullRange, of: sourceTrack, at: .zero)
        if mediaType == .video {
            targetTrack.preferredTransform = sourceTrack.preferredTransform
        }
        copiedTrackCount += 1
    }
}

guard copiedTrackCount > 0 else {
    throw OrdinaryMetadataError.noTracksToCopy
}

try? FileManager.default.removeItem(at: outputURL)

let metadata: [AVMetadataItem] = [
    commonItem(identifier: .commonIdentifierTitle, value: "Ordinary metadata TC \(timecode)"),
    commonItem(identifier: .commonIdentifierDescription, value: "Start TC \(timecode) stored only as ordinary metadata strings."),
    quickTimeItem(key: "timecode", value: timecode),
    quickTimeItem(key: "com.apple.quicktime.timecode", value: timecode),
    quickTimeItem(key: "Start TC", value: timecode),
    quickTimeItem(key: "start_timecode", value: timecode),
    quickTimeItem(key: "source_timecode", value: timecode)
]

guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
    throw OrdinaryMetadataError.exportSessionUnavailable
}

exportSession.outputURL = outputURL
exportSession.outputFileType = .mov
exportSession.metadata = metadata
exportSession.shouldOptimizeForNetworkUse = false

let semaphore = DispatchSemaphore(value: 0)
exportSession.exportAsynchronously {
    semaphore.signal()
}
semaphore.wait()

guard exportSession.status == .completed else {
    throw OrdinaryMetadataError.exportFailed(exportSession.error?.localizedDescription ?? "\(exportSession.status.rawValue)")
}

print(outputURL.path)
