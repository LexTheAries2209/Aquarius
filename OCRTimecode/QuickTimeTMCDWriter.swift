import Foundation

struct QuickTimeTMCDBurnReport: Sendable {
    let sampleCount: Int
    let oldFirstFrame: String?
    let oldLastFrame: String?
    let newFirstFrame: String
    let newLastFrame: String
    let oldFrameRate: Int
    let newFrameRate: Int

    nonisolated init(
        sampleCount: Int,
        oldFirstFrame: String?,
        oldLastFrame: String?,
        newFirstFrame: String,
        newLastFrame: String,
        oldFrameRate: Int,
        newFrameRate: Int
    ) {
        self.sampleCount = sampleCount
        self.oldFirstFrame = oldFirstFrame
        self.oldLastFrame = oldLastFrame
        self.newFirstFrame = newFirstFrame
        self.newLastFrame = newLastFrame
        self.oldFrameRate = oldFrameRate
        self.newFrameRate = newFrameRate
    }
}

enum QuickTimeTMCDWriter {
    nonisolated static func writeStartTimecode(_ timecode: Timecode, to url: URL) throws -> QuickTimeTMCDBurnReport {
        guard timecode.fps > 0, timecode.fps <= Int(UInt8.max) else {
            throw QuickTimeTMCDWriterError.invalidTimecode(timecode.description)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let track = try findTMCDTrack(data)
        guard !track.sampleOffsets.isEmpty else {
            throw QuickTimeTMCDWriterError.unsupported("TMCD 轨道没有可写入的 sample")
        }

        let targetFrameNumber = timecode.totalFrames
        guard targetFrameNumber >= 0,
              targetFrameNumber + track.sampleOffsets.count - 1 <= Int(UInt32.max) else {
            throw QuickTimeTMCDWriterError.unsupported("目标时间码帧号超出 QuickTime TMCD 可写范围")
        }

        let oldFirstFrameNumber = try readU32(data, track.sampleOffsets[0])
        let oldLastFrameNumber = try readU32(data, track.sampleOffsets[track.sampleOffsets.count - 1])
        let oldFrameRate = track.framesPerSecond
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }

        try writeU32(handle, at: track.timeScaleOffset, value: UInt32(timecode.fps))
        try writeU32(handle, at: track.frameDurationOffset, value: 1)
        try writeU8(handle, at: track.framesPerSecondOffset, value: UInt8(timecode.fps))

        for (index, offset) in track.sampleOffsets.enumerated() {
            let frameNumber = targetFrameNumber + index
            try writeU32(handle, at: offset, value: UInt32(frameNumber))
        }

        try handle.synchronize()
        let newLastFrameNumber = targetFrameNumber + track.sampleOffsets.count - 1
        return QuickTimeTMCDBurnReport(
            sampleCount: track.sampleOffsets.count,
            oldFirstFrame: formatFrameNumber(Int(oldFirstFrameNumber), fps: oldFrameRate),
            oldLastFrame: formatFrameNumber(Int(oldLastFrameNumber), fps: oldFrameRate),
            newFirstFrame: timecode.description,
            newLastFrame: formatFrameNumber(newLastFrameNumber, fps: timecode.fps),
            oldFrameRate: oldFrameRate,
            newFrameRate: timecode.fps
        )
    }

    nonisolated private static func findTMCDTrack(_ data: Data) throws -> TMCDTrackLayout {
        let topLevel = try parseAtoms(data, range: 0..<data.count)
        guard let moov = topLevel.first(where: { $0.type == "moov" }) else {
            throw QuickTimeTMCDWriterError.invalidAtom("缺少 moov atom")
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
                data: data,
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
                throw QuickTimeTMCDWriterError.unsupported("TMCD samples 不是 4 字节布局")
            }

            return TMCDTrackLayout(
                timeScaleOffset: sampleDescription.timeScaleOffset,
                frameDurationOffset: sampleDescription.frameDurationOffset,
                framesPerSecondOffset: sampleDescription.framesPerSecondOffset,
                framesPerSecond: sampleDescription.framesPerSecond,
                sampleOffsets: sampleOffsets
            )
        }

        throw QuickTimeTMCDWriterError.missingTMCDTrack
    }

    nonisolated private static func parseAtoms(_ data: Data, range: Range<Int>) throws -> [MOVAtom] {
        var atoms: [MOVAtom] = []
        var offset = range.lowerBound

        while offset + 8 <= range.upperBound {
            let smallSize = try readU32(data, offset)
            let type = try readType(data, offset + 4)
            var headerSize = 8
            let atomSize: Int

            if smallSize == 1 {
                let extendedSize = try readU64(data, offset + 8)
                guard extendedSize <= UInt64(Int.max) else {
                    throw QuickTimeTMCDWriterError.invalidAtom("\(type) atom 过大")
                }
                atomSize = Int(extendedSize)
                headerSize = 16
            } else if smallSize == 0 {
                atomSize = range.upperBound - offset
            } else {
                atomSize = Int(smallSize)
            }

            guard atomSize >= headerSize else {
                throw QuickTimeTMCDWriterError.invalidAtom("\(type) atom size 异常")
            }
            guard offset + atomSize <= range.upperBound else {
                throw QuickTimeTMCDWriterError.invalidAtom("\(type) atom 超出父级范围")
            }

            atoms.append(MOVAtom(type: type, start: offset, headerSize: headerSize, size: atomSize))
            offset += atomSize
        }

        return atoms
    }

    nonisolated private static func child(_ data: Data, _ atom: MOVAtom, _ type: String) throws -> MOVAtom? {
        try parseAtoms(data, range: atom.contentStart..<atom.end).first { $0.type == type }
    }

    nonisolated private static func parseHandler(_ data: Data, _ hdlr: MOVAtom) throws -> String {
        try readType(data, hdlr.contentStart + 8)
    }

    nonisolated private static func parseSTSD(_ data: Data, _ stsd: MOVAtom) throws -> TMCDSampleDescription {
        let entryCount = try readU32(data, stsd.contentStart + 4)
        guard entryCount > 0 else {
            throw QuickTimeTMCDWriterError.unsupported("stsd 没有 sample description")
        }

        let entryOffset = stsd.contentStart + 8
        let entrySize = Int(try readU32(data, entryOffset))
        let format = try readType(data, entryOffset + 4)
        guard format == "tmcd" else {
            throw QuickTimeTMCDWriterError.unsupported("stsd 第一项是 \(format)，不是 tmcd")
        }
        guard entryOffset + entrySize <= stsd.end, entrySize >= 34 else {
            throw QuickTimeTMCDWriterError.invalidAtom("tmcd sample description 不完整")
        }

        let timeScaleOffset = entryOffset + 24
        let frameDurationOffset = entryOffset + 28
        let framesPerSecondOffset = entryOffset + 32
        let framesPerSecond = Int(try readU8(data, framesPerSecondOffset))
        guard framesPerSecond > 0 else {
            throw QuickTimeTMCDWriterError.unsupported("tmcd numberOfFrames 为 0")
        }

        return TMCDSampleDescription(
            timeScaleOffset: timeScaleOffset,
            frameDurationOffset: frameDurationOffset,
            framesPerSecondOffset: framesPerSecondOffset,
            framesPerSecond: framesPerSecond
        )
    }

    nonisolated private static func parseSTSZ(_ data: Data, _ stsz: MOVAtom) throws -> (sampleCount: Int, sampleSizes: [Int]) {
        let sampleSize = Int(try readU32(data, stsz.contentStart + 4))
        let sampleCount = Int(try readU32(data, stsz.contentStart + 8))
        if sampleSize != 0 {
            return (sampleCount, Array(repeating: sampleSize, count: sampleCount))
        }

        var sizes: [Int] = []
        var offset = stsz.contentStart + 12
        for _ in 0..<sampleCount {
            sizes.append(Int(try readU32(data, offset)))
            offset += 4
        }
        return (sampleCount, sizes)
    }

    nonisolated private static func parseSTSC(_ data: Data, _ stsc: MOVAtom) throws -> [TMCDSTSCEntry] {
        let entryCount = Int(try readU32(data, stsc.contentStart + 4))
        var entries: [TMCDSTSCEntry] = []
        var offset = stsc.contentStart + 8
        for _ in 0..<entryCount {
            entries.append(TMCDSTSCEntry(
                firstChunk: Int(try readU32(data, offset)),
                samplesPerChunk: Int(try readU32(data, offset + 4))
            ))
            offset += 12
        }
        return entries
    }

    nonisolated private static func parseChunkOffsets(data: Data, stco: MOVAtom?, co64: MOVAtom?) throws -> [Int] {
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
                    throw QuickTimeTMCDWriterError.invalidAtom("co64 offset 过大")
                }
                offsets.append(Int(value))
                offset += 8
            }
            return offsets
        }

        throw QuickTimeTMCDWriterError.unsupported("缺少 stco/co64 chunk offset 表")
    }

    nonisolated private static func buildSampleOffsets(
        chunkOffsets: [Int],
        stscEntries: [TMCDSTSCEntry],
        sampleSizes: [Int],
        fileSize: Int
    ) throws -> [Int] {
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
                    throw QuickTimeTMCDWriterError.invalidAtom("tmcd sample 指向文件范围外")
                }

                offsets.append(sampleOffset)
                chunkRelativeOffset += sampleSize
                sampleIndex += 1
            }
        }

        guard offsets.count == sampleSizes.count else {
            throw QuickTimeTMCDWriterError.unsupported("sample table 无法解析完整 sample 偏移")
        }
        return offsets
    }

    nonisolated private static func samplesPerChunk(for chunkIndex: Int, entries: [TMCDSTSCEntry]) throws -> Int {
        guard !entries.isEmpty else {
            throw QuickTimeTMCDWriterError.unsupported("stsc 为空")
        }

        var selected = entries[0]
        for entry in entries where entry.firstChunk <= chunkIndex {
            selected = entry
        }
        return selected.samplesPerChunk
    }

    nonisolated private static func readU8(_ data: Data, _ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else {
            throw QuickTimeTMCDWriterError.invalidAtom("readU8 越界")
        }
        return data[offset]
    }

    nonisolated private static func readU32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw QuickTimeTMCDWriterError.invalidAtom("readU32 越界")
        }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[offset + index])
        }
        return value
    }

    nonisolated private static func readU64(_ data: Data, _ offset: Int) throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw QuickTimeTMCDWriterError.invalidAtom("readU64 越界")
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    nonisolated private static func readType(_ data: Data, _ offset: Int) throws -> String {
        guard offset + 4 <= data.count else {
            throw QuickTimeTMCDWriterError.invalidAtom("atom type 越界")
        }
        return String(bytes: data[offset..<(offset + 4)], encoding: .macOSRoman) ?? "????"
    }

    nonisolated private static func writeU8(_ handle: FileHandle, at offset: Int, value: UInt8) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data([value]))
    }

    nonisolated private static func writeU32(_ handle: FileHandle, at offset: Int, value: UInt32) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]))
    }

    nonisolated private static func formatFrameNumber(_ frameNumber: Int, fps: Int) -> String {
        Timecode.from(totalFrames: frameNumber, fps: max(1, fps)).description
    }
}

private struct MOVAtom: Sendable {
    let type: String
    let start: Int
    let headerSize: Int
    let size: Int

    nonisolated init(type: String, start: Int, headerSize: Int, size: Int) {
        self.type = type
        self.start = start
        self.headerSize = headerSize
        self.size = size
    }

    nonisolated var contentStart: Int { start + headerSize }
    nonisolated var end: Int { start + size }
}

private struct TMCDSampleDescription: Sendable {
    let timeScaleOffset: Int
    let frameDurationOffset: Int
    let framesPerSecondOffset: Int
    let framesPerSecond: Int

    nonisolated init(
        timeScaleOffset: Int,
        frameDurationOffset: Int,
        framesPerSecondOffset: Int,
        framesPerSecond: Int
    ) {
        self.timeScaleOffset = timeScaleOffset
        self.frameDurationOffset = frameDurationOffset
        self.framesPerSecondOffset = framesPerSecondOffset
        self.framesPerSecond = framesPerSecond
    }
}

private struct TMCDSTSCEntry: Sendable {
    let firstChunk: Int
    let samplesPerChunk: Int

    nonisolated init(firstChunk: Int, samplesPerChunk: Int) {
        self.firstChunk = firstChunk
        self.samplesPerChunk = samplesPerChunk
    }
}

private struct TMCDTrackLayout: Sendable {
    let timeScaleOffset: Int
    let frameDurationOffset: Int
    let framesPerSecondOffset: Int
    let framesPerSecond: Int
    let sampleOffsets: [Int]

    nonisolated init(
        timeScaleOffset: Int,
        frameDurationOffset: Int,
        framesPerSecondOffset: Int,
        framesPerSecond: Int,
        sampleOffsets: [Int]
    ) {
        self.timeScaleOffset = timeScaleOffset
        self.frameDurationOffset = frameDurationOffset
        self.framesPerSecondOffset = framesPerSecondOffset
        self.framesPerSecond = framesPerSecond
        self.sampleOffsets = sampleOffsets
    }
}

enum QuickTimeTMCDWriterError: LocalizedError, Sendable {
    case invalidTimecode(String)
    case invalidAtom(String)
    case missingTMCDTrack
    case unsupported(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidTimecode(let value):
            "时间码不合法：\(value)"
        case .invalidAtom(let message):
            "MOV 结构异常：\(message)"
        case .missingTMCDTrack:
            "未找到可写入的 QuickTime TMCD 轨道"
        case .unsupported(let message):
            "不支持的 TMCD 布局：\(message)"
        }
    }
}
