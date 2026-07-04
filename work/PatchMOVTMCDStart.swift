import Foundation

struct Atom {
    let type: String
    let start: Int
    let headerSize: Int
    let size: Int

    var contentStart: Int { start + headerSize }
    var end: Int { start + size }
}

struct STSCEntry {
    let firstChunk: Int
    let samplesPerChunk: Int
    let sampleDescriptionIndex: Int
}

struct TMCDTrack {
    let trakStart: Int
    let timeScale: Int
    let frameDuration: Int
    let framesPerSecond: Int
    let flags: UInt32
    let sampleCount: Int
    let sampleSize: Int
    let chunkOffsets: [Int]
    let stscEntries: [STSCEntry]
    let sampleOffsets: [Int]
}

enum PatchError: Error, CustomStringConvertible {
    case usage
    case invalidTimecode(String)
    case invalidAtom(String)
    case missingTMCDTrack
    case unsupported(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: PatchMOVTMCDStart <input.mov> <output.mov> <HH:MM:SS:FF>"
        case .invalidTimecode(let value):
            return "Invalid timecode: \(value)"
        case .invalidAtom(let message):
            return "Invalid MOV atom structure: \(message)"
        case .missingTMCDTrack:
            return "No tmcd track found"
        case .unsupported(let message):
            return "Unsupported tmcd layout: \(message)"
        }
    }
}

func readU8(_ data: Data, _ offset: Int) throws -> UInt8 {
    guard offset >= 0, offset < data.count else {
        throw PatchError.invalidAtom("readU8 out of range at \(offset)")
    }
    return data[offset]
}

func readU16(_ data: Data, _ offset: Int) throws -> UInt16 {
    guard offset + 2 <= data.count else {
        throw PatchError.invalidAtom("readU16 out of range at \(offset)")
    }
    var value: UInt16 = 0
    for index in 0..<2 {
        value = (value << 8) | UInt16(data[offset + index])
    }
    return value
}

func readU32(_ data: Data, _ offset: Int) throws -> UInt32 {
    guard offset + 4 <= data.count else {
        throw PatchError.invalidAtom("readU32 out of range at \(offset)")
    }
    var value: UInt32 = 0
    for index in 0..<4 {
        value = (value << 8) | UInt32(data[offset + index])
    }
    return value
}

func readU64(_ data: Data, _ offset: Int) throws -> UInt64 {
    guard offset + 8 <= data.count else {
        throw PatchError.invalidAtom("readU64 out of range at \(offset)")
    }
    var value: UInt64 = 0
    for index in 0..<8 {
        value = (value << 8) | UInt64(data[offset + index])
    }
    return value
}

func readType(_ data: Data, _ offset: Int) throws -> String {
    guard offset + 4 <= data.count else {
        throw PatchError.invalidAtom("type out of range at \(offset)")
    }
    return String(bytes: data[offset..<(offset + 4)], encoding: .macOSRoman) ?? "????"
}

func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) throws {
    guard offset + 4 <= data.count else {
        throw PatchError.invalidAtom("writeU32 out of range at \(offset)")
    }
    data[offset] = UInt8((value >> 24) & 0xff)
    data[offset + 1] = UInt8((value >> 16) & 0xff)
    data[offset + 2] = UInt8((value >> 8) & 0xff)
    data[offset + 3] = UInt8(value & 0xff)
}

func parseAtoms(_ data: Data, range: Range<Int>) throws -> [Atom] {
    var atoms: [Atom] = []
    var offset = range.lowerBound

    while offset + 8 <= range.upperBound {
        let smallSize = try readU32(data, offset)
        let type = try readType(data, offset + 4)
        var headerSize = 8
        var atomSize: Int

        if smallSize == 1 {
            let extendedSize = try readU64(data, offset + 8)
            guard extendedSize <= UInt64(Int.max) else {
                throw PatchError.invalidAtom("atom \(type) too large")
            }
            atomSize = Int(extendedSize)
            headerSize = 16
        } else if smallSize == 0 {
            atomSize = range.upperBound - offset
        } else {
            atomSize = Int(smallSize)
        }

        guard atomSize >= headerSize else {
            throw PatchError.invalidAtom("atom \(type) has invalid size \(atomSize)")
        }
        guard offset + atomSize <= range.upperBound else {
            throw PatchError.invalidAtom("atom \(type) exceeds parent range")
        }

        atoms.append(Atom(type: type, start: offset, headerSize: headerSize, size: atomSize))
        offset += atomSize
    }

    return atoms
}

func child(_ data: Data, _ atom: Atom, _ type: String) throws -> Atom? {
    try parseAtoms(data, range: atom.contentStart..<atom.end).first { $0.type == type }
}

func parseHandler(_ data: Data, _ hdlr: Atom) throws -> String {
    let handlerOffset = hdlr.contentStart + 8
    return try readType(data, handlerOffset)
}

func parseSTSD(_ data: Data, _ stsd: Atom) throws -> (flags: UInt32, timeScale: Int, frameDuration: Int, framesPerSecond: Int) {
    let entryCount = try readU32(data, stsd.contentStart + 4)
    guard entryCount > 0 else {
        throw PatchError.unsupported("stsd has no sample descriptions")
    }

    let entryOffset = stsd.contentStart + 8
    let entrySize = Int(try readU32(data, entryOffset))
    let format = try readType(data, entryOffset + 4)
    guard format == "tmcd" else {
        throw PatchError.unsupported("first stsd entry is \(format), expected tmcd")
    }
    guard entryOffset + entrySize <= stsd.end, entrySize >= 34 else {
        throw PatchError.invalidAtom("tmcd sample description is truncated")
    }

    // QuickTime tmcd descriptions in this QTAKE file include an extra reserved
    // UInt32 after the generic sample-entry header.
    let flags = try readU32(data, entryOffset + 20)
    let timeScale = Int(try readU32(data, entryOffset + 24))
    let frameDuration = Int(try readU32(data, entryOffset + 28))
    let framesPerSecond = Int(try readU8(data, entryOffset + 32))
    guard framesPerSecond > 0 else {
        throw PatchError.unsupported("tmcd numberOfFrames is zero")
    }

    return (flags, timeScale, frameDuration, framesPerSecond)
}

func parseSTSZ(_ data: Data, _ stsz: Atom) throws -> (sampleSize: Int, sampleCount: Int, sampleSizes: [Int]) {
    let sampleSize = Int(try readU32(data, stsz.contentStart + 4))
    let sampleCount = Int(try readU32(data, stsz.contentStart + 8))
    if sampleSize != 0 {
        return (sampleSize, sampleCount, Array(repeating: sampleSize, count: sampleCount))
    }

    var sizes: [Int] = []
    var offset = stsz.contentStart + 12
    for _ in 0..<sampleCount {
        sizes.append(Int(try readU32(data, offset)))
        offset += 4
    }
    return (sampleSize, sampleCount, sizes)
}

func parseSTSC(_ data: Data, _ stsc: Atom) throws -> [STSCEntry] {
    let entryCount = Int(try readU32(data, stsc.contentStart + 4))
    var entries: [STSCEntry] = []
    var offset = stsc.contentStart + 8
    for _ in 0..<entryCount {
        entries.append(STSCEntry(
            firstChunk: Int(try readU32(data, offset)),
            samplesPerChunk: Int(try readU32(data, offset + 4)),
            sampleDescriptionIndex: Int(try readU32(data, offset + 8))
        ))
        offset += 12
    }
    return entries
}

func parseChunkOffsets(_ data: Data, stco: Atom?, co64: Atom?) throws -> [Int] {
    if let stco {
        let entryCount = Int(try readU32(data, stco.contentStart + 4))
        var offsets: [Int] = []
        var offset = stco.contentStart + 8
        for _ in 0..<entryCount {
            offsets.append(Int(try readU32(data, offset)))
            offset += 4
        }
        return offsets
    }

    if let co64 {
        let entryCount = Int(try readU32(data, co64.contentStart + 4))
        var offsets: [Int] = []
        var offset = co64.contentStart + 8
        for _ in 0..<entryCount {
            let value = try readU64(data, offset)
            guard value <= UInt64(Int.max) else {
                throw PatchError.invalidAtom("co64 offset too large")
            }
            offsets.append(Int(value))
            offset += 8
        }
        return offsets
    }

    throw PatchError.unsupported("missing stco/co64")
}

func samplesPerChunk(for chunkIndex: Int, entries: [STSCEntry]) throws -> Int {
    guard !entries.isEmpty else {
        throw PatchError.unsupported("empty stsc")
    }

    var selected = entries[0]
    for entry in entries where entry.firstChunk <= chunkIndex {
        selected = entry
    }
    return selected.samplesPerChunk
}

func buildSampleOffsets(chunkOffsets: [Int], stscEntries: [STSCEntry], sampleSizes: [Int], fileSize: Int) throws -> [Int] {
    var offsets: [Int] = []
    var sampleIndex = 0

    for chunkIndex in 1...chunkOffsets.count {
        let samplesInChunk = try samplesPerChunk(for: chunkIndex, entries: stscEntries)
        var chunkRelativeOffset = 0
        let chunkOffset = chunkOffsets[chunkIndex - 1]

        for _ in 0..<samplesInChunk {
            guard sampleIndex < sampleSizes.count else {
                return offsets
            }

            let sampleOffset = chunkOffset + chunkRelativeOffset
            let sampleSize = sampleSizes[sampleIndex]
            guard sampleOffset >= 0, sampleOffset + sampleSize <= fileSize else {
                throw PatchError.invalidAtom("sample \(sampleIndex) points outside file")
            }

            offsets.append(sampleOffset)
            chunkRelativeOffset += sampleSize
            sampleIndex += 1
        }
    }

    guard offsets.count == sampleSizes.count else {
        throw PatchError.unsupported("sample table resolved \(offsets.count) offsets for \(sampleSizes.count) samples")
    }
    return offsets
}

func findTMCDTrack(_ data: Data) throws -> TMCDTrack {
    let topLevel = try parseAtoms(data, range: 0..<data.count)
    guard let moov = topLevel.first(where: { $0.type == "moov" }) else {
        throw PatchError.invalidAtom("missing moov")
    }

    for trak in try parseAtoms(data, range: moov.contentStart..<moov.end) where trak.type == "trak" {
        guard
            let mdia = try child(data, trak, "mdia"),
            let hdlr = try child(data, mdia, "hdlr"),
            try parseHandler(data, hdlr) == "tmcd",
            let minf = try child(data, mdia, "minf"),
            let stbl = try child(data, minf, "stbl"),
            let stsd = try child(data, stbl, "stsd"),
            let stsz = try child(data, stbl, "stsz"),
            let stsc = try child(data, stbl, "stsc")
        else {
            continue
        }

        let sampleDescription = try parseSTSD(data, stsd)
        let sampleSizesInfo = try parseSTSZ(data, stsz)
        let stscEntries = try parseSTSC(data, stsc)
        let chunkOffsets = try parseChunkOffsets(
            data,
            stco: try child(data, stbl, "stco"),
            co64: try child(data, stbl, "co64")
        )
        let sampleOffsets = try buildSampleOffsets(
            chunkOffsets: chunkOffsets,
            stscEntries: stscEntries,
            sampleSizes: sampleSizesInfo.sampleSizes,
            fileSize: data.count
        )

        guard sampleSizesInfo.sampleSizes.allSatisfy({ $0 == 4 }) else {
            throw PatchError.unsupported("tmcd samples are not all 4 bytes")
        }

        return TMCDTrack(
            trakStart: trak.start,
            timeScale: sampleDescription.timeScale,
            frameDuration: sampleDescription.frameDuration,
            framesPerSecond: sampleDescription.framesPerSecond,
            flags: sampleDescription.flags,
            sampleCount: sampleSizesInfo.sampleCount,
            sampleSize: sampleSizesInfo.sampleSize,
            chunkOffsets: chunkOffsets,
            stscEntries: stscEntries,
            sampleOffsets: sampleOffsets
        )
    }

    throw PatchError.missingTMCDTrack
}

func parseTimecode(_ value: String, fps: Int) throws -> Int {
    let parts = value.split(separator: ":")
    guard parts.count == 4,
          let hours = Int(parts[0]),
          let minutes = Int(parts[1]),
          let seconds = Int(parts[2]),
          let frames = Int(parts[3]),
          (0...23).contains(hours),
          (0...59).contains(minutes),
          (0...59).contains(seconds),
          (0..<fps).contains(frames)
    else {
        throw PatchError.invalidTimecode(value)
    }

    return ((hours * 3600 + minutes * 60 + seconds) * fps) + frames
}

func formatFrameNumber(_ frameNumber: Int, fps: Int) -> String {
    let framesPerHour = fps * 60 * 60
    let framesPerMinute = fps * 60
    let normalized = ((frameNumber % (framesPerHour * 24)) + (framesPerHour * 24)) % (framesPerHour * 24)
    let hours = normalized / framesPerHour
    let minutes = (normalized % framesPerHour) / framesPerMinute
    let seconds = (normalized % framesPerMinute) / fps
    let frames = normalized % fps
    return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
}

func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 else {
        throw PatchError.usage
    }

    let inputURL = URL(fileURLWithPath: arguments[1])
    let outputURL = URL(fileURLWithPath: arguments[2])
    let targetTimecode = arguments[3]

    var data = try Data(contentsOf: inputURL)
    let track = try findTMCDTrack(data)
    let targetFrameNumber = try parseTimecode(targetTimecode, fps: track.framesPerSecond)
    let oldFirstFrameNumber = Int(try readU32(data, track.sampleOffsets[0]))
    let oldLastFrameNumber = Int(try readU32(data, track.sampleOffsets[track.sampleOffsets.count - 1]))

    for (index, offset) in track.sampleOffsets.enumerated() {
        let patchedFrameNumber = targetFrameNumber + index
        guard patchedFrameNumber >= 0, patchedFrameNumber <= Int(UInt32.max) else {
            throw PatchError.unsupported("patched frame number outside UInt32 range")
        }
        try writeU32(&data, offset, UInt32(patchedFrameNumber))
    }

    try data.write(to: outputURL, options: .atomic)

    print("tmcd track offset: \(track.trakStart)")
    print("tmcd sample count: \(track.sampleCount)")
    print("tmcd chunks: \(track.chunkOffsets.count)")
    print("tmcd timescale/frameDuration: \(track.timeScale)/\(track.frameDuration)")
    print("tmcd numberOfFrames: \(track.framesPerSecond)")
    print("tmcd flags: 0x\(String(track.flags, radix: 16))")
    print("old first frame: \(oldFirstFrameNumber) (\(formatFrameNumber(oldFirstFrameNumber, fps: track.framesPerSecond)))")
    print("old last frame: \(oldLastFrameNumber) (\(formatFrameNumber(oldLastFrameNumber, fps: track.framesPerSecond)))")
    print("new first frame: \(targetFrameNumber) (\(formatFrameNumber(targetFrameNumber, fps: track.framesPerSecond)))")
    print("new last frame: \(targetFrameNumber + track.sampleOffsets.count - 1) (\(formatFrameNumber(targetFrameNumber + track.sampleOffsets.count - 1, fps: track.framesPerSecond)))")
    print("wrote: \(outputURL.path)")
}

do {
    try main()
} catch let error as PatchError {
    fputs("\(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
