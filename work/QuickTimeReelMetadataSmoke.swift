// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Foundation

enum ReelSmokeError: Error {
    case exportSessionUnavailable
    case invalidMode(String)
    case exportFailed(String)
}

func commonTitleItem(_ value: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = .commonIdentifierTitle
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

func quickTimeItem(key: String, value: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = key as NSString
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

guard CommandLine.arguments.count == 6 else {
    print("Usage: QuickTimeReelMetadataSmoke <input.mov> <output.mov> <mode> <title> <reel>")
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let mode = CommandLine.arguments[3]
let title = CommandLine.arguments[4]
let reel = CommandLine.arguments[5]

let extraItems: [AVMutableMetadataItem]
switch mode {
case "qt-reel":
    extraItems = [
        commonTitleItem(title),
        quickTimeItem(key: "com.apple.quicktime.reel", value: reel)
    ]
case "reel-name":
    extraItems = [
        commonTitleItem(title),
        quickTimeItem(key: "reel_name", value: reel)
    ]
case "literal-reel-name":
    extraItems = [
        commonTitleItem(title),
        quickTimeItem(key: "Reel Name", value: reel)
    ]
case "qt-reelname":
    extraItems = [
        commonTitleItem(title),
        quickTimeItem(key: "com.apple.quicktime.reelname", value: reel)
    ]
case "all":
    extraItems = [
        commonTitleItem(title),
        quickTimeItem(key: "Reel Name", value: reel),
        quickTimeItem(key: "com.apple.quicktime.reel", value: reel),
        quickTimeItem(key: "com.apple.quicktime.reelname", value: reel),
        quickTimeItem(key: "reel_name", value: reel),
        quickTimeItem(key: "reel", value: reel),
        quickTimeItem(key: "tape", value: reel)
    ]
default:
    throw ReelSmokeError.invalidMode(mode)
}

try? FileManager.default.removeItem(at: outputURL)

let asset = AVURLAsset(url: inputURL)
guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
    throw ReelSmokeError.exportSessionUnavailable
}

exportSession.outputURL = outputURL
exportSession.outputFileType = .mov
exportSession.metadata = asset.metadata + extraItems

let semaphore = DispatchSemaphore(value: 0)
exportSession.exportAsynchronously {
    semaphore.signal()
}
semaphore.wait()

if exportSession.status != .completed {
    throw ReelSmokeError.exportFailed(exportSession.error?.localizedDescription ?? "\(exportSession.status.rawValue)")
}

print(outputURL.path)
