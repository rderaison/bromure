import Foundation

// Pure-Swift Zstandard decompressor (RFC 8878), decode only.
//
// Why it exists: agents compress their request bodies with
// `Content-Encoding: zstd` (Grok Build CLI on its /v1/responses turns, Codex
// on chatgpt.com), and the MITM proxy has to read those bodies for the PII
// swap and the prompt-injection scan. macOS ships no zstd decoder
// (Compression.framework has zlib / lzma / lz4 / lzfse / brotli only) and we
// don't link third-party C libraries, so the format is decoded here.
//
// Scope: every frame shape a stock encoder produces without a dictionary —
// raw / RLE / compressed blocks, raw / RLE / Huffman / treeless literals
// (1 or 4 streams), predefined / RLE / FSE / repeat sequence tables, repeat
// offsets, concatenated frames, skippable frames, and the optional XXH64
// content checksum (verified when present). Frames that need a dictionary
// are rejected (`.unsupported`). Output is capped (`maxOutput`) so a
// decompression bomb can't exhaust memory. All input is treated as hostile:
// every index is bounds-checked and malformed data throws, never traps.

enum ZstdError: Error, Equatable {
    case corrupt(String)
    case unsupported(String)
    case outputTooLarge
    case checksumMismatch
}

enum Zstd {
    static let frameMagic: UInt32 = 0xFD2F_B528
    /// The largest block a frame may carry (Block_Maximum_Size).
    static let maxBlockSize = 128 * 1024

    /// True when `data` starts with a zstd (or skippable) frame magic.
    static func hasFrameMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(4))
        let m = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return m == frameMagic || m & 0xFFFF_FFF0 == 0x184D_2A50
    }

    /// Decompress one or more concatenated zstd frames.
    static func decompress(_ data: Data, maxOutput: Int = 64 * 1024 * 1024) throws -> Data {
        let src = [UInt8](data)
        guard !src.isEmpty else { throw ZstdError.corrupt("empty input") }
        var out = [UInt8]()
        var pos = 0
        var sawFrame = false
        while pos < src.count {
            guard pos + 4 <= src.count else { throw ZstdError.corrupt("truncated frame magic") }
            let magic = le32(src, pos)
            if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                // Skippable frame: 4-byte magic, 4-byte size, user data.
                guard pos + 8 <= src.count else { throw ZstdError.corrupt("truncated skippable frame") }
                let size = Int(le32(src, pos + 4))
                guard size <= src.count - pos - 8 else { throw ZstdError.corrupt("truncated skippable frame") }
                pos += 8 + size
                continue
            }
            guard magic == frameMagic else { throw ZstdError.corrupt("bad frame magic") }
            pos += 4
            try decodeFrame(src, &pos, &out, maxOutput: maxOutput)
            sawFrame = true
        }
        guard sawFrame else { throw ZstdError.corrupt("no zstd frame") }
        return Data(out)
    }

    // MARK: - Frame

    /// Per-frame decoder state carried across blocks.
    private struct FrameState {
        var rep: (Int, Int, Int) = (1, 4, 8)
        var huffman: HuffmanTable? = nil
        var llTable: FSETable? = nil
        var ofTable: FSETable? = nil
        var mlTable: FSETable? = nil
    }

    private static func decodeFrame(_ src: [UInt8], _ pos: inout Int, _ out: inout [UInt8],
                                    maxOutput: Int) throws {
        guard pos < src.count else { throw ZstdError.corrupt("truncated frame header") }
        let fhd = src[pos]; pos += 1
        let fcsFlag = Int(fhd >> 6)
        let singleSegment = fhd & 0x20 != 0
        let hasChecksum = fhd & 0x04 != 0
        let dictFlag = Int(fhd & 0x03)
        guard fhd & 0x08 == 0 else { throw ZstdError.corrupt("reserved frame header bit set") }
        if !singleSegment {
            guard pos < src.count else { throw ZstdError.corrupt("truncated window descriptor") }
            let exponent = Int(src[pos] >> 3)
            pos += 1
            // Window_Log above 31 is beyond what any decoder supports.
            guard 10 + exponent <= 41 else { throw ZstdError.unsupported("window too large") }
        }
        let dictIDSize = [0, 1, 2, 4][dictFlag]
        guard pos + dictIDSize <= src.count else { throw ZstdError.corrupt("truncated dictionary id") }
        var dictID: UInt32 = 0
        for i in 0..<dictIDSize { dictID |= UInt32(src[pos + i]) << (8 * i) }
        pos += dictIDSize
        guard dictID == 0 else { throw ZstdError.unsupported("frame needs dictionary \(dictID)") }
        let fcsSize = fcsFlag == 0 ? (singleSegment ? 1 : 0) : [0, 2, 4, 8][fcsFlag]
        guard pos + fcsSize <= src.count else { throw ZstdError.corrupt("truncated content size") }
        var contentSize: UInt64? = nil
        if fcsSize > 0 {
            var v: UInt64 = 0
            for i in 0..<fcsSize { v |= UInt64(src[pos + i]) << (8 * UInt64(i)) }
            if fcsSize == 2 { v += 256 }
            contentSize = v
        }
        pos += fcsSize
        let frameStart = out.count
        if let cs = contentSize {
            guard cs <= UInt64(maxOutput - out.count) else { throw ZstdError.outputTooLarge }
            out.reserveCapacity(out.count + Int(cs))
        }

        var state = FrameState()
        while true {
            guard pos + 3 <= src.count else { throw ZstdError.corrupt("truncated block header") }
            let bh = Int(src[pos]) | Int(src[pos + 1]) << 8 | Int(src[pos + 2]) << 16
            pos += 3
            let last = bh & 1 != 0
            let type = (bh >> 1) & 3
            let size = bh >> 3
            switch type {
            case 0: // Raw
                guard size <= src.count - pos else { throw ZstdError.corrupt("truncated raw block") }
                guard size <= maxOutput - out.count else { throw ZstdError.outputTooLarge }
                out.append(contentsOf: src[pos..<(pos + size)])
                pos += size
            case 1: // RLE
                guard pos < src.count else { throw ZstdError.corrupt("truncated RLE block") }
                guard size <= maxOutput - out.count else { throw ZstdError.outputTooLarge }
                out.append(contentsOf: repeatElement(src[pos], count: size))
                pos += 1
            case 2: // Compressed
                guard size <= maxBlockSize else { throw ZstdError.corrupt("compressed block too large") }
                guard size <= src.count - pos else { throw ZstdError.corrupt("truncated compressed block") }
                try decodeCompressedBlock(src, pos, pos + size, &out, frameStart: frameStart,
                                          state: &state, maxOutput: maxOutput)
                pos += size
            default:
                throw ZstdError.corrupt("reserved block type")
            }
            if last { break }
        }
        if let cs = contentSize, UInt64(out.count - frameStart) != cs {
            throw ZstdError.corrupt("frame content size mismatch")
        }
        if hasChecksum {
            guard pos + 4 <= src.count else { throw ZstdError.corrupt("truncated checksum") }
            let want = le32(src, pos)
            pos += 4
            let got = out.withUnsafeBufferPointer { buf in
                UInt32(truncatingIfNeeded: xxh64(UnsafeBufferPointer(rebasing: buf[frameStart...]), seed: 0))
            }
            guard want == got else { throw ZstdError.checksumMismatch }
        }
    }

    // MARK: - Compressed block

    private static func decodeCompressedBlock(_ src: [UInt8], _ start: Int, _ end: Int,
                                              _ out: inout [UInt8], frameStart: Int,
                                              state: inout FrameState, maxOutput: Int) throws {
        var p = start
        let literals = try decodeLiterals(src, &p, end, state: &state)

        guard p < end else { throw ZstdError.corrupt("missing sequences section") }
        let b0 = Int(src[p]); p += 1
        let nbSeq: Int
        if b0 == 0 {
            nbSeq = 0
        } else if b0 < 128 {
            nbSeq = b0
        } else if b0 < 255 {
            guard p < end else { throw ZstdError.corrupt("truncated sequence count") }
            nbSeq = ((b0 - 128) << 8) + Int(src[p]); p += 1
        } else {
            guard p + 2 <= end else { throw ZstdError.corrupt("truncated sequence count") }
            nbSeq = Int(src[p]) + (Int(src[p + 1]) << 8) + 0x7F00; p += 2
        }

        if nbSeq == 0 {
            guard literals.count <= maxOutput - out.count else { throw ZstdError.outputTooLarge }
            out.append(contentsOf: literals)
            return
        }

        guard p < end else { throw ZstdError.corrupt("missing compression modes") }
        let modes = src[p]; p += 1
        guard modes & 0x03 == 0 else { throw ZstdError.corrupt("reserved compression mode bits") }
        let llTable = try sequenceTable(mode: Int(modes >> 6) & 3, kind: .literalLength,
                                        src, &p, end, previous: state.llTable)
        let ofTable = try sequenceTable(mode: Int(modes >> 4) & 3, kind: .offset,
                                        src, &p, end, previous: state.ofTable)
        let mlTable = try sequenceTable(mode: Int(modes >> 2) & 3, kind: .matchLength,
                                        src, &p, end, previous: state.mlTable)
        state.llTable = llTable
        state.ofTable = ofTable
        state.mlTable = mlTable

        var br = try BackwardBitReader(src, p, end)
        var llState = Int(br.read(llTable.log))
        var ofState = Int(br.read(ofTable.log))
        var mlState = Int(br.read(mlTable.log))
        var litPos = 0
        var rep = state.rep

        for i in 0..<nbSeq {
            let llCell = llTable.cells[llState]
            let ofCell = ofTable.cells[ofState]
            let mlCell = mlTable.cells[mlState]
            let llCode = Int(llCell.symbol), ofCode = Int(ofCell.symbol), mlCode = Int(mlCell.symbol)
            guard llCode <= 35, mlCode <= 52 else { throw ZstdError.corrupt("bad length code") }
            guard ofCode <= 31 else { throw ZstdError.corrupt("bad offset code") }

            // Extra bits: offset, then match length, then literal length.
            let offsetValue = (1 << ofCode) + Int(br.read(ofCode))
            let matchLength = mlBaseline[mlCode] + Int(br.read(mlExtraBits[mlCode]))
            let literalLength = llBaseline[llCode] + Int(br.read(llExtraBits[llCode]))

            // Repeat offsets (RFC 8878 §3.1.2.5).
            let offset: Int
            if offsetValue > 3 {
                offset = offsetValue - 3
                rep = (offset, rep.0, rep.1)
            } else {
                let idx = literalLength == 0 ? offsetValue : offsetValue - 1
                switch idx {
                case 0:
                    offset = rep.0
                case 1:
                    offset = rep.1
                    rep = (rep.1, rep.0, rep.2)
                case 2:
                    offset = rep.2
                    rep = (rep.2, rep.0, rep.1)
                default: // 3: only reachable with literalLength == 0
                    offset = rep.0 - 1
                    guard offset > 0 else { throw ZstdError.corrupt("zero repeat offset") }
                    rep = (offset, rep.0, rep.1)
                }
            }

            // Execute: literals, then the match.
            guard literalLength <= literals.count - litPos else { throw ZstdError.corrupt("literal length overrun") }
            guard literalLength <= maxOutput - out.count,
                  matchLength <= maxOutput - out.count - literalLength else { throw ZstdError.outputTooLarge }
            if literalLength > 0 {
                out.append(contentsOf: literals[litPos..<(litPos + literalLength)])
                litPos += literalLength
            }
            guard offset > 0, offset <= out.count - frameStart else { throw ZstdError.corrupt("offset beyond output") }
            let from = out.count - offset
            let to = out.count
            out.append(contentsOf: repeatElement(0, count: matchLength))
            // Forward byte copy: when the match overlaps its own output
            // (offset < matchLength) this repeats the run, as the format requires.
            out.withUnsafeMutableBufferPointer { buf in
                for k in 0..<matchLength { buf[to + k] = buf[from + k] }
            }

            if i != nbSeq - 1 {
                // State updates: literal length, match length, offset.
                llState = llCell.baseline + Int(br.read(llCell.nbBits))
                mlState = mlCell.baseline + Int(br.read(mlCell.nbBits))
                ofState = ofCell.baseline + Int(br.read(ofCell.nbBits))
            }
        }
        guard br.position == 0 else { throw ZstdError.corrupt("sequence bitstream not fully consumed") }
        state.rep = rep
        let rest = literals.count - litPos
        guard rest <= maxOutput - out.count else { throw ZstdError.outputTooLarge }
        if rest > 0 { out.append(contentsOf: literals[litPos...]) }
    }

    // MARK: - Literals

    private static func decodeLiterals(_ src: [UInt8], _ p: inout Int, _ end: Int,
                                       state: inout FrameState) throws -> [UInt8] {
        guard p < end else { throw ZstdError.corrupt("missing literals section") }
        let b0 = Int(src[p])
        let type = b0 & 3
        let sizeFormat = (b0 >> 2) & 3
        switch type {
        case 0, 1: // Raw, RLE
            let regen: Int
            switch sizeFormat {
            case 0, 2:
                regen = b0 >> 3; p += 1
            case 1:
                guard p + 2 <= end else { throw ZstdError.corrupt("truncated literals header") }
                regen = (b0 >> 4) + (Int(src[p + 1]) << 4); p += 2
            default:
                guard p + 3 <= end else { throw ZstdError.corrupt("truncated literals header") }
                regen = (b0 >> 4) + (Int(src[p + 1]) << 4) + (Int(src[p + 2]) << 12); p += 3
            }
            guard regen <= maxBlockSize else { throw ZstdError.corrupt("literals too large") }
            if type == 0 {
                guard regen <= end - p else { throw ZstdError.corrupt("truncated raw literals") }
                let lit = Array(src[p..<(p + regen)])
                p += regen
                return lit
            } else {
                guard p < end else { throw ZstdError.corrupt("truncated RLE literals") }
                let lit = [UInt8](repeating: src[p], count: regen)
                p += 1
                return lit
            }
        default: // 2 Compressed, 3 Treeless
            let headerSize = sizeFormat <= 1 ? 3 : (sizeFormat == 2 ? 4 : 5)
            guard p + headerSize <= end else { throw ZstdError.corrupt("truncated literals header") }
            var h: UInt64 = 0
            for i in 0..<headerSize { h |= UInt64(src[p + i]) << (8 * UInt64(i)) }
            let n: UInt64 = sizeFormat <= 1 ? 10 : (sizeFormat == 2 ? 14 : 18)
            let mask: UInt64 = (1 << n) - 1
            let regen = Int((h >> 4) & mask)
            let compressed = Int((h >> (4 + n)) & mask)
            let streams = sizeFormat == 0 ? 1 : 4
            p += headerSize
            guard regen <= maxBlockSize else { throw ZstdError.corrupt("literals too large") }
            guard compressed <= end - p else { throw ZstdError.corrupt("truncated compressed literals") }
            let cend = p + compressed
            var q = p
            if type == 2 {
                state.huffman = try readHuffmanTable(src, &q, cend)
            }
            guard let table = state.huffman else { throw ZstdError.corrupt("treeless literals without a table") }
            var lit = [UInt8]()
            lit.reserveCapacity(regen)
            if streams == 1 {
                try decodeHuffmanStream(src, q, cend, table, count: regen, into: &lit)
            } else {
                guard q + 6 <= cend else { throw ZstdError.corrupt("truncated jump table") }
                let s1 = Int(src[q]) | Int(src[q + 1]) << 8
                let s2 = Int(src[q + 2]) | Int(src[q + 3]) << 8
                let s3 = Int(src[q + 4]) | Int(src[q + 5]) << 8
                q += 6
                let s4 = cend - q - s1 - s2 - s3
                guard s4 > 0 else { throw ZstdError.corrupt("bad jump table") }
                let seg = (regen + 3) / 4
                let lastSeg = regen - 3 * seg
                guard lastSeg >= 0 else { throw ZstdError.corrupt("bad literal stream sizes") }
                try decodeHuffmanStream(src, q, q + s1, table, count: seg, into: &lit)
                try decodeHuffmanStream(src, q + s1, q + s1 + s2, table, count: seg, into: &lit)
                try decodeHuffmanStream(src, q + s1 + s2, q + s1 + s2 + s3, table, count: seg, into: &lit)
                try decodeHuffmanStream(src, q + s1 + s2 + s3, cend, table, count: lastSeg, into: &lit)
            }
            p = cend
            return lit
        }
    }

    // MARK: - Huffman

    struct HuffmanTable {
        let maxBits: Int
        let symbols: [UInt8]
        let nbBits: [UInt8]
    }

    private static func readHuffmanTable(_ src: [UInt8], _ q: inout Int, _ end: Int) throws -> HuffmanTable {
        guard q < end else { throw ZstdError.corrupt("missing Huffman header") }
        let header = Int(src[q]); q += 1
        var weights: [UInt8]
        if header >= 128 {
            let n = header - 127
            let bytes = (n + 1) / 2
            guard bytes <= end - q else { throw ZstdError.corrupt("truncated Huffman weights") }
            weights = []
            weights.reserveCapacity(n + 1)
            for i in 0..<n {
                let byte = src[q + i / 2]
                weights.append(i % 2 == 0 ? byte >> 4 : byte & 0x0F)
            }
            q += bytes
        } else {
            guard header > 0, header <= end - q else { throw ZstdError.corrupt("bad Huffman weights size") }
            weights = try decodeFSEWeights(src, q, q + header)
            q += header
        }
        return try buildHuffmanTable(weights)
    }

    static func buildHuffmanTable(_ given: [UInt8]) throws -> HuffmanTable {
        var weights = given
        guard weights.count <= 255 else { throw ZstdError.corrupt("too many Huffman weights") }
        var sum = 0
        for w in weights {
            guard w <= 11 else { throw ZstdError.corrupt("Huffman weight too large") }
            if w > 0 { sum += 1 << (Int(w) - 1) }
        }
        guard sum > 0 else { throw ZstdError.corrupt("empty Huffman table") }
        let maxBits = highBit(sum) + 1
        guard maxBits <= 11 else { throw ZstdError.corrupt("Huffman code too long") }
        let total = 1 << maxBits
        let rest = total - sum
        guard rest > 0, rest & (rest - 1) == 0 else { throw ZstdError.corrupt("bad implied Huffman weight") }
        weights.append(UInt8(highBit(rest) + 1))
        var symbols = [UInt8](repeating: 0, count: total)
        var bits = [UInt8](repeating: 0, count: total)
        var next = 0
        for w in 1...maxBits {
            let span = 1 << (w - 1)
            let nb = UInt8(maxBits + 1 - w)
            for (sym, sw) in weights.enumerated() where Int(sw) == w {
                guard next + span <= total else { throw ZstdError.corrupt("Huffman table overflow") }
                for k in next..<(next + span) { symbols[k] = UInt8(sym); bits[k] = nb }
                next += span
            }
        }
        guard next == total else { throw ZstdError.corrupt("Huffman table incomplete") }
        return HuffmanTable(maxBits: maxBits, symbols: symbols, nbBits: bits)
    }

    private static func decodeHuffmanStream(_ src: [UInt8], _ start: Int, _ end: Int,
                                            _ table: HuffmanTable, count: Int,
                                            into out: inout [UInt8]) throws {
        guard start <= end else { throw ZstdError.corrupt("bad Huffman stream bounds") }
        if count == 0 && start == end { return }
        var br = try BackwardBitReader(src, start, end)
        for _ in 0..<count {
            let v = Int(br.peek(table.maxBits))
            out.append(table.symbols[v])
            br.consume(Int(table.nbBits[v]))
        }
        guard br.position == 0 else { throw ZstdError.corrupt("Huffman stream not fully consumed") }
    }

    /// Huffman weights compressed with FSE: two interleaved states.
    private static func decodeFSEWeights(_ src: [UInt8], _ start: Int, _ end: Int) throws -> [UInt8] {
        var p = start
        let table = try readFSETable(src, &p, end, maxSymbol: 255, maxLog: 6)
        var br = try BackwardBitReader(src, p, end)
        var s1 = Int(br.read(table.log))
        var s2 = Int(br.read(table.log))
        var out = [UInt8]()
        while true {
            guard out.count < 255 else { throw ZstdError.corrupt("too many Huffman weights") }
            let c1 = table.cells[s1]
            out.append(UInt8(truncatingIfNeeded: c1.symbol))
            s1 = c1.baseline + Int(br.read(c1.nbBits))
            if br.position < 0 { out.append(UInt8(truncatingIfNeeded: table.cells[s2].symbol)); break }
            let c2 = table.cells[s2]
            out.append(UInt8(truncatingIfNeeded: c2.symbol))
            s2 = c2.baseline + Int(br.read(c2.nbBits))
            if br.position < 0 { out.append(UInt8(truncatingIfNeeded: table.cells[s1].symbol)); break }
        }
        guard out.count <= 255 else { throw ZstdError.corrupt("too many Huffman weights") }
        return out
    }

    // MARK: - FSE

    struct FSECell {
        let symbol: UInt16
        let nbBits: Int
        let baseline: Int
    }

    struct FSETable {
        let log: Int
        let cells: [FSECell]
    }

    private enum SequenceKind { case literalLength, offset, matchLength }

    private static func sequenceTable(mode: Int, kind: SequenceKind, _ src: [UInt8], _ p: inout Int,
                                      _ end: Int, previous: FSETable?) throws -> FSETable {
        let maxSymbol: Int, maxLog: Int
        switch kind {
        case .literalLength: maxSymbol = 35; maxLog = 9
        case .offset: maxSymbol = 31; maxLog = 8
        case .matchLength: maxSymbol = 52; maxLog = 9
        }
        switch mode {
        case 0: // Predefined
            switch kind {
            case .literalLength: return predefinedLL
            case .offset: return predefinedOF
            case .matchLength: return predefinedML
            }
        case 1: // RLE
            guard p < end else { throw ZstdError.corrupt("truncated RLE table") }
            let s = Int(src[p]); p += 1
            guard s <= maxSymbol else { throw ZstdError.corrupt("RLE symbol out of range") }
            return FSETable(log: 0, cells: [FSECell(symbol: UInt16(s), nbBits: 0, baseline: 0)])
        case 2: // FSE_Compressed
            return try readFSETable(src, &p, end, maxSymbol: maxSymbol, maxLog: maxLog)
        default: // Repeat
            guard let previous else { throw ZstdError.corrupt("repeat table without a previous one") }
            return previous
        }
    }

    /// Read an FSE table description (forward bitstream) and build its
    /// decoding table. Advances `p` past the description.
    private static func readFSETable(_ src: [UInt8], _ p: inout Int, _ end: Int,
                                     maxSymbol: Int, maxLog: Int) throws -> FSETable {
        var fr = ForwardBitReader(src, p, end)
        let log = Int(fr.read(4)) + 5
        guard log <= maxLog else { throw ZstdError.corrupt("FSE accuracy log too large") }
        var remaining = (1 << log) + 1
        var threshold = 1 << log
        var nbBits = log + 1
        var probs: [Int] = []
        var previousZero = false
        while remaining > 1 {
            if previousZero {
                var zeros = 0
                while true {
                    let r = Int(fr.read(2))
                    zeros += r
                    if r != 3 { break }
                    guard !fr.overrun else { throw ZstdError.corrupt("truncated FSE table") }
                }
                guard probs.count + zeros <= maxSymbol + 1 else { throw ZstdError.corrupt("FSE symbol out of range") }
                probs.append(contentsOf: repeatElement(0, count: zeros))
            }
            guard probs.count <= maxSymbol else { throw ZstdError.corrupt("FSE symbol out of range") }
            let maxValue = (2 * threshold - 1) - remaining
            var count: Int
            let low = Int(fr.peek(nbBits - 1))
            if low < maxValue {
                count = low
                fr.consume(nbBits - 1)
            } else {
                count = Int(fr.peek(nbBits))
                if count >= threshold { count -= maxValue }
                fr.consume(nbBits)
            }
            count -= 1
            guard abs(count) <= remaining - 1 else { throw ZstdError.corrupt("FSE probabilities overflow") }
            remaining -= abs(count)
            probs.append(count)
            previousZero = count == 0
            while remaining < threshold && nbBits > 1 {
                nbBits -= 1
                threshold >>= 1
            }
            guard !fr.overrun else { throw ZstdError.corrupt("truncated FSE table") }
        }
        guard remaining == 1, !fr.overrun else { throw ZstdError.corrupt("bad FSE table") }
        p += (fr.bitPosition + 7) / 8
        return try buildFSETable(probs, log: log)
    }

    static func buildFSETable(_ probs: [Int], log: Int) throws -> FSETable {
        let size = 1 << log
        var symbols = [UInt16](repeating: 0, count: size)
        var high = size - 1
        var next = [Int](repeating: 0, count: probs.count)
        for (s, prob) in probs.enumerated() {
            if prob == -1 {
                guard high >= 0 else { throw ZstdError.corrupt("FSE table overflow") }
                symbols[high] = UInt16(s)
                high -= 1
                next[s] = 1
            } else {
                next[s] = prob
            }
        }
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var pos = 0
        for (s, prob) in probs.enumerated() where prob > 0 {
            for _ in 0..<prob {
                symbols[pos] = UInt16(s)
                repeat { pos = (pos + step) & mask } while pos > high
            }
        }
        guard pos == 0 else { throw ZstdError.corrupt("FSE spread failed") }
        var cells = [FSECell]()
        cells.reserveCapacity(size)
        for u in 0..<size {
            let s = Int(symbols[u])
            let ns = next[s]
            next[s] += 1
            guard ns > 0 else { throw ZstdError.corrupt("FSE state underflow") }
            let nb = log - highBit(ns)
            cells.append(FSECell(symbol: UInt16(s), nbBits: nb, baseline: (ns << nb) - size))
        }
        return FSETable(log: log, cells: cells)
    }

    // Predefined distributions (RFC 8878 §3.1.1.3.2.2).
    static let predefinedLL: FSETable = try! buildFSETable(
        [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
         2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1], log: 6)
    static let predefinedML: FSETable = try! buildFSETable(
        [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
         1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
         -1, -1, -1, -1, -1], log: 6)
    static let predefinedOF: FSETable = try! buildFSETable(
        [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
         -1, -1, -1, -1, -1], log: 5)

    static let llBaseline: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536]
    static let llExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16]
    static let mlBaseline: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16387, 32771, 65539]
    static let mlExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16]

    // MARK: - Bit readers

    /// Reads a zstd backward bitstream: starts at the last byte's highest set
    /// bit (the end marker) and moves toward the first byte. Reading past
    /// the start yields zero bits and drives `position` negative.
    struct BackwardBitReader {
        private let src: [UInt8]
        private let start: Int
        private let end: Int
        /// Bits not yet read (negative once the reader ran past the start).
        private(set) var position: Int

        init(_ src: [UInt8], _ start: Int, _ end: Int) throws {
            guard start < end, end <= src.count else { throw ZstdError.corrupt("empty bitstream") }
            let last = src[end - 1]
            guard last != 0 else { throw ZstdError.corrupt("bitstream missing end marker") }
            self.src = src
            self.start = start
            self.end = end
            self.position = (end - start - 1) * 8 + Zstd.highBit(Int(last))
        }

        /// Bits [lo, lo + n) of the stream, lo >= 0, n <= 56.
        @inline(__always)
        private func extract(_ lo: Int, _ n: Int) -> UInt64 {
            let byteIndex = start + (lo >> 3)
            var v: UInt64 = 0
            let avail = Swift.min(8, end - byteIndex)
            var i = 0
            while i < avail { v |= UInt64(src[byteIndex + i]) << UInt64(8 * i); i += 1 }
            return (v >> UInt64(lo & 7)) & ((1 << UInt64(n)) - 1)
        }

        @inline(__always)
        func peek(_ n: Int) -> UInt64 {
            if n == 0 { return 0 }
            let lo = position - n
            if lo >= 0 { return extract(lo, n) }
            let have = n + lo
            if have <= 0 { return 0 }
            return extract(0, have) << UInt64(-lo)
        }

        @inline(__always)
        mutating func consume(_ n: Int) { position -= n }

        @inline(__always)
        mutating func read(_ n: Int) -> UInt64 {
            let v = peek(n)
            position -= n
            return v
        }
    }

    /// Little-endian forward bitstream (FSE table descriptions).
    struct ForwardBitReader {
        private let src: [UInt8]
        private let start: Int
        private let end: Int
        private(set) var bitPosition = 0

        init(_ src: [UInt8], _ start: Int, _ end: Int) {
            self.src = src
            self.start = start
            self.end = Swift.min(end, src.count)
        }

        var overrun: Bool { start + (bitPosition + 7) / 8 > end }

        func peek(_ n: Int) -> UInt64 {
            if n == 0 { return 0 }
            let byteIndex = start + (bitPosition >> 3)
            var v: UInt64 = 0
            var i = 0
            while i < 8, byteIndex + i < end { v |= UInt64(src[byteIndex + i]) << UInt64(8 * i); i += 1 }
            return (v >> UInt64(bitPosition & 7)) & ((1 << UInt64(n)) - 1)
        }

        mutating func consume(_ n: Int) { bitPosition += n }

        mutating func read(_ n: Int) -> UInt64 {
            let v = peek(n)
            bitPosition += n
            return v
        }
    }

    // MARK: - Helpers

    @inline(__always)
    static func highBit(_ x: Int) -> Int { Int.bitWidth - 1 - x.leadingZeroBitCount }

    @inline(__always)
    private static func le32(_ s: [UInt8], _ i: Int) -> UInt32 {
        UInt32(s[i]) | UInt32(s[i + 1]) << 8 | UInt32(s[i + 2]) << 16 | UInt32(s[i + 3]) << 24
    }

    // MARK: - XXH64

    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    static func xxh64(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { raw in xxh64(raw.bindMemory(to: UInt8.self), seed: seed) }
    }

    static func xxh64(_ b: UnsafeBufferPointer<UInt8>, seed: UInt64) -> UInt64 {
        let len = b.count
        @inline(__always) func r64(_ i: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
            return v
        }
        @inline(__always) func r32(_ i: Int) -> UInt64 {
            UInt64(b[i]) | UInt64(b[i + 1]) << 8 | UInt64(b[i + 2]) << 16 | UInt64(b[i + 3]) << 24
        }
        var i = 0
        var h: UInt64
        if len >= 32 {
            var v1 = seed &+ p1 &+ p2, v2 = seed &+ p2, v3 = seed, v4 = seed &- p1
            while i + 32 <= len {
                v1 = round(v1, r64(i)); v2 = round(v2, r64(i + 8))
                v3 = round(v3, r64(i + 16)); v4 = round(v4, r64(i + 24))
                i += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1); h = merge(h, v2); h = merge(h, v3); h = merge(h, v4)
        } else {
            h = seed &+ p5
        }
        h = h &+ UInt64(len)
        while i + 8 <= len {
            h ^= round(0, r64(i))
            h = rotl(h, 27) &* p1 &+ p4
            i += 8
        }
        if i + 4 <= len {
            h ^= r32(i) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            i += 4
        }
        while i < len {
            h ^= UInt64(b[i]) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }
        h ^= h >> 33; h = h &* p2
        h ^= h >> 29; h = h &* p3
        h ^= h >> 32
        return h
    }
}
