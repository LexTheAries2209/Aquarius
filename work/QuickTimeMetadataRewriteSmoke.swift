// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Foundation

enum SmokeError: Error {
    case exportSessionUnavailable
    case exportFailed(String)
}

func metadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

func quickTimeMetadataItem(key: String, value: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = key as NSString
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

try? FileManager.default.removeItem(at: outputURL)

let asset = AVURLAsset(url: inputURL)
guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
    throw SmokeError.exportSessionUnavailable
}

exportSession.outputURL = outputURL
exportSession.outputFileType = .mov
exportSession.metadata = asset.metadata + [
    metadataItem(identifier: .commonIdentifierTitle, value: "SWIFT_METADATA_TITLE_A001"),
    quickTimeMetadataItem(key: "com.apple.quicktime.displayname", value: "SWIFT_DISPLAY_A001"),
    quickTimeMetadataItem(key: "com.apple.quicktime.reel", value: "A001"),
    quickTimeMetadataItem(key: "com.apple.quicktime.timecode", value: "11:22:33:12")
]

let semaphore = DispatchSemaphore(value: 0)
exportSession.exportAsynchronously {
    semaphore.signal()
}
semaphore.wait()

if exportSession.status != .completed {
    throw SmokeError.exportFailed(exportSession.error?.localizedDescription ?? "\(exportSession.status.rawValue)")
}

print(outputURL.path)
