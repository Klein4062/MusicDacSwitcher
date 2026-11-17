// SourceProbe.swift — 源格式探测：发现正在播放的本地音频文件并解析其真实格式
//
// 原理：播放器播放本地文件时文件句柄处于打开状态（lsof 可见），
//       直接解析文件头（FLAC/WAV/AIFF/DSF）得到采样率/位深/声道，
//       从而突破"共享输出模式下系统不暴露源格式"的限制。

import Foundation

public enum SourceProbe {

    public struct Probe: Equatable, CustomStringConvertible {
        public var path: String
        public var sampleRate: Float64
        public var bitsPerSample: Int?
        public var channels: Int?
        public var kind: String
        /// 持有句柄的进程（lsof）
        public var pid: Int?
        /// 文件当前读取偏移（字节）。播放中持续推进；残留句柄停滞。
        public var offset: UInt64?

        public var description: String {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let bits = bitsPerSample.map { "/\($0)bit" } ?? ""
            let ch = channels.map { " \($0)ch" } ?? ""
            return "\(name) [\(kind) \(hz(sampleRate))\(bits)\(ch)]"
        }

        public var key: String { "\(path)|\(sampleRate)|\(bitsPerSample ?? 0)" }
    }

    /// 可解析头部的音频扩展名（其余扩展名即使被打开也不解析）
    static let parseableExtensions: Set<String> = ["flac", "wav", "aif", "aiff", "dsf", "dff", "m4a", "uc!"]
    /// 被播放器打开的其他媒体（仅供提示，暂不解析）
    static let mediaExtensions: Set<String> = ["m4a", "mp3", "ape", "ogg", "opus", "wv", "wma"]

    /// 网易云音乐在线播放缓存（.uc!）：内容是整文件单字节 XOR 0xA3 的
    /// 普通音频（实测 96k/24bit FLAC 与 320k AAC/M4A 均为此密钥）。
    /// 只读取文件头的技术元数据（采样率/位深）用于匹配输出格式，
    /// 不解密、不保存音频内容。
    static let neteaseUCKey: UInt8 = 0xA3

    static func isNeteaseUC(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "uc!"
    }

    static let maxHeaderBytes = 512 * 1024

    /// lsof 输出中的单个打开文件记录
    struct LsofFile {
        let path: String
        let pid: Int
        let offset: UInt64?
    }

    /// 扫描系统当前打开的音频文件并解析格式（约 0.2s，含读取偏移）
    public static func scan() -> [Probe] {
        // 同一文件可能被开多个 fd：按路径聚合，offset 取最大
        var info = [String: (pid: Int, offset: UInt64)]()
        var order = [String]()
        for f in runLsofFiles() {
            let ext = (f.path as NSString).pathExtension.lowercased()
            guard parseableExtensions.contains(ext) else { continue }
            if let cur = info[f.path] {
                info[f.path] = (f.pid, Swift.max(cur.offset, f.offset ?? 0))
            } else {
                order.append(f.path)
                info[f.path] = (f.pid, f.offset ?? 0)
            }
        }
        return order.compactMap { path in
            guard let meta = info[path], var p = parseHeader(path) else { return nil }
            p.pid = meta.pid
            p.offset = meta.offset
            return p
        }
    }

    /// 从两次快照中挑出「正在播放」的文件：
    /// 播放中的文件句柄读取偏移持续前进；播放器残留句柄（播放列表预读、
    /// 播完未关闭等）offset 停滞。因此：
    ///   1. offset 前进者优先，前进量最大者优先（读取速率 ≈ 播放码率）
    ///   2. 有 offset 信息但全部停滞 → 返回 nil（全是残留，不可信）
    ///   3. 完全无 offset 信息（如 mmap，lsof 拿不到偏移）→ 回退采样率最高
    public static func pickPlaying(a: [Probe], b: [Probe]) -> Probe? {
        guard !b.isEmpty else { return nil }
        let prev = Dictionary(a.map { ($0.path, $0.offset ?? 0) }, uniquingKeysWith: { Swift.max($0, $1) })
        var bestAdvance: (p: Probe, delta: UInt64)?
        var sawOffsetInfo = false
        for p in b {
            guard let cur = p.offset else { continue }
            sawOffsetInfo = true
            guard let before = prev[p.path], cur > before else { continue }
            let delta = cur - before
            if bestAdvance == nil || delta > bestAdvance!.delta {
                bestAdvance = (p, delta)
            }
        }
        if let best = bestAdvance?.p { return best }
        if sawOffsetInfo { return nil } // 全部停滞：残留句柄，不信任
        return b.max(by: { $0.sampleRate < $1.sampleRate })
    }

    /// lsof -w -n -o -F pfaon → 每个数字 fd 对应的 (path, pid, offset)。
    /// 只保留读句柄：网易云边下边播时会同时持有同一缓存的读/写句柄，
    /// 写句柄（下载）offset 前进远快于播放，会把「正在播放」判定带偏。
    static func runLsofFiles() -> [LsofFile] {
        parseLsofOutput(runLsof())
    }

    static func parseLsofOutput(_ output: String) -> [LsofFile] {
        var files = [LsofFile]()
        var pid = 0
        var fdIsNumeric = false
        var offset: UInt64?
        var writeMode = false
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let rest = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int(rest) ?? 0
                fdIsNumeric = false
            case "f": // f10 = 普通 fd；ftxt/fcwd/frtd 等非数字则跳过
                fdIsNumeric = Int(rest) != nil
                offset = nil
                writeMode = false
            case "a": // 访问模式：r=只读 u=读写 w=只写
                writeMode = rest.lowercased().contains("w") && !rest.lowercased().contains("u")
            case "o":
                offset = parseOffset(rest)
            case "n":
                if fdIsNumeric, !writeMode {
                    files.append(LsofFile(path: rest, pid: pid, offset: offset))
                }
                fdIsNumeric = false
                offset = nil
                writeMode = false
            default:
                break
            }
        }
        return files
    }

    /// "0t548680" / "548680" → 548680；其余（0x…、空）→ nil
    static func parseOffset(_ s: String) -> UInt64? {
        var t = s
        if t.hasPrefix("0t") { t.removeFirst(2) }
        return UInt64(t)
    }

    static func runLsof() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-w", "-n", "-o", "-F", "pfaon"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 文件头解析

    public static func parseHeader(_ path: String) -> Probe? {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? fh.close() }
        guard let data = (try? fh.read(upToCount: maxHeaderBytes)).flatMap({ $0 }),
              data.count >= 26 else { return nil } // 各格式解析器内部有精确长度保护
        if isNeteaseUC(path) {
            return parseUC(data, path) ?? parseUCTail(fh, path)
        }
        return parseFLAC(data, path)
            ?? parseMP4(data, path)
            ?? parseWAV(data, path)
            ?? parseAIFF(data, path)
            ?? parseDSF(data, path)
    }

    /// 网易云 .uc! 缓存：整体 XOR 解出文件头再按普通格式解析。
    /// 解不出则尝试文件尾（M4A 的 moov 常在文件末尾）。
    static func parseUC(_ data: Data, _ path: String) -> Probe? {
        let plain = Data(data.map { $0 ^ neteaseUCKey })
        var p = parseFLAC(plain, path)
            ?? parseMP4(plain, path)
            ?? parseWAV(plain, path)
            ?? parseAIFF(plain, path)
            ?? parseDSF(plain, path)
        if p != nil { p!.kind += "·网易云" }
        return p
    }

    static func parseUCTail(_ fh: FileHandle, _ path: String) -> Probe? {
        let end = (try? fh.seekToEnd()) ?? 0
        guard end > maxHeaderBytes else { return nil }
        fh.seek(toFileOffset: end - UInt64(maxHeaderBytes))
        guard let data = (try? fh.read(upToCount: maxHeaderBytes)).flatMap({ $0 }) else { return nil }
        var p = parseMP4(data, path)
        if p != nil { p!.kind += "·网易云" }
        return p
    }

    /// MP4/M4A：遍历 moov→trak→mdia，取音频轨（handler 'soun'）的 mdhd timescale。
    /// AAC 为有损编码，位深无意义 → bitsPerSample 置 nil（不参与位深匹配）。
    static func parseMP4(_ d: Data, _ path: String) -> Probe? {
        struct Box {
            var type: String
            var start: Int
            var end: Int
        }
        func boxes(_ lo: Int, _ hi: Int) -> [Box] {
            var out = [Box]()
            var off = lo
            while off + 8 <= hi {
                let sizeRaw = Int(be32(d, off))
                guard off + 8 <= hi else { break }
                let type = String(data: d[(off + 4) ..< min(off + 8, hi)], encoding: .ascii) ?? ""
                var size = sizeRaw
                if sizeRaw == 1 { // 64 位长度在 payload 前 8 字节
                    guard off + 16 <= hi else { break }
                    var s = 0
                    for k in 0..<8 { s = (s << 8) | Int(d[off + 8 + k]) }
                    size = s
                }
                guard size >= 8, off + size <= hi else { break }
                out.append(Box(type: type, start: off + 8, end: off + size))
                off += size
            }
            return out
        }
        let i = d.startIndex
        guard let moov = boxes(i, d.endIndex).first(where: { $0.type == "moov" }) else { return nil }
        for trak in boxes(moov.start, moov.end) where trak.type == "trak" {
            guard let mdia = boxes(trak.start, trak.end).first(where: { $0.type == "mdia" }) else { continue }
            let inner = boxes(mdia.start, mdia.end)
            guard let hdlr = inner.first(where: { $0.type == "hdlr" }),
                  hdlr.end - hdlr.start >= 12,
                  d[hdlr.start + 8 ..< hdlr.start + 12] == Data("soun".utf8) else { continue }
            guard let mdhd = inner.first(where: { $0.type == "mdhd" }),
                  mdhd.end > mdhd.start else { continue }
            let version = d[mdhd.start]
            let tsOff = mdhd.start + (version == 1 ? 20 : 12)
            guard tsOff + 4 <= mdhd.end else { continue }
            let ts = be32(d, tsOff)
            guard ts > 0 else { continue }
            return Probe(path: path, sampleRate: Float64(ts),
                         bitsPerSample: nil, channels: nil, kind: "M4A")
        }
        return nil
    }

    /// FLAC: "fLaC" + STREAMINFO(type 0) 固定 bitfield
    static func parseFLAC(_ d: Data, _ path: String) -> Probe? {
        let i = d.startIndex
        guard d.count >= i + 26, d[i ..< i + 4] == Data("fLaC".utf8) else { return nil }
        guard d[i + 4] & 0x7F == 0 else { return nil } // 首块必须是 STREAMINFO
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(d[i + 18 + k]) }
        let sampleRate = Float64((v >> 44) & 0xFFFFF)
        let channels = Int((v >> 41) & 0x7) + 1
        let bits = Int((v >> 36) & 0x1F) + 1
        guard sampleRate > 0 else { return nil }
        return Probe(path: path, sampleRate: sampleRate,
                     bitsPerSample: bits, channels: channels, kind: "FLAC")
    }

    /// WAV: RIFF/WAVE，遍历 chunk 找 "fmt "
    static func parseWAV(_ d: Data, _ path: String) -> Probe? {
        let i = d.startIndex
        guard d.count >= i + 44,
              d[i ..< i + 4] == Data("RIFF".utf8),
              d[i + 8 ..< i + 12] == Data("WAVE".utf8) else { return nil }
        var off = i + 12
        while off + 8 < d.endIndex {
            let size = Int(le32(d, off + 4))
            guard size > 0, off + 8 + min(size, 40) <= d.endIndex else { break }
            if d[off ..< off + 4] == Data("fmt ".utf8), size >= 16 {
                let b = off + 8
                let channels = Int(le16(d, b + 2))
                let rate = Float64(le32(d, b + 4))
                let bits = Int(le16(d, b + 14))
                guard rate > 0, channels > 0 else { return nil }
                return Probe(path: path, sampleRate: rate,
                             bitsPerSample: bits, channels: channels, kind: "WAV")
            }
            off += 8 + size + (size & 1) // chunk 按 2 字节对齐
        }
        return nil
    }

    /// AIFF/AIFC: FORM....COMM，采样率为 80-bit IEEE extended
    static func parseAIFF(_ d: Data, _ path: String) -> Probe? {
        let i = d.startIndex
        guard d.count > i + 12,
              d[i ..< i + 4] == Data("FORM".utf8),
              be32(d, i + 8) == 0x41494646 || be32(d, i + 8) == 0x41494643 else { return nil } // AIFF/AIFC
        var off = i + 12
        while off + 8 < d.endIndex {
            let cid = be32(d, off)
            let size = Int(be32(d, off + 4))
            if cid == 0x434F4D4D /* COMM */, size >= 18, off + 8 + 18 <= d.endIndex { // swiftlint:disable:this line_length
                let b = off + 8
                let channels = Int(be16(d, b))
                let bits = Int(be16(d, b + 8))
                let rate = extended80(d, b + 10)
                guard rate > 0, channels > 0 else { return nil }
                return Probe(path: path, sampleRate: rate,
                             bitsPerSample: bits, channels: channels, kind: "AIFF")
            }
            guard size > 0 else { break }
            off += 8 + size + (size & 1)
        }
        return nil
    }

    /// DSF: "DSD " + 固定偏移的 "fmt " chunk
    static func parseDSF(_ d: Data, _ path: String) -> Probe? {
        let i = d.startIndex
        guard d.count > i + 56, d[i ..< i + 4] == Data("DSD ".utf8) else { return nil }
        // DSD chunk 头 12 字节后是 "fmt " chunk；fmt 内容自 offset 28 起
        let b = i + 28
        guard d[i + 12 ..< i + 16] == Data("fmt ".utf8) else { return nil }
        let channels = Int(le32(d, b + 12))
        let freqEnum = le32(d, b + 16)
        let dsdRate: Float64
        switch freqEnum {
        case 1: dsdRate = 2_822_400   // DSD64
        case 2: dsdRate = 5_644_800   // DSD128
        case 3: dsdRate = 11_289_600  // DSD256
        default: dsdRate = Float64(freqEnum)
        }
        guard dsdRate > 0 else { return nil }
        return Probe(path: path, sampleRate: dsdRate,
                     bitsPerSample: 1, channels: channels, kind: "DSD")
    }

    // MARK: - 字节序工具

    static func le16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }

    static func le32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }

    static func be16(_ d: Data, _ o: Int) -> UInt16 {
        (UInt16(d[o]) << 8) | UInt16(d[o + 1])
    }

    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
    }

    /// 80-bit IEEE 754 extended（大端）→ Double
    static func extended80(_ d: Data, _ o: Int) -> Double {
        guard o + 10 <= d.endIndex else { return 0 }
        let rawExp = (Int(d[o]) << 8) | Int(d[o + 1])
        let exp = (rawExp & 0x7FFF) - 16383
        var mantissa: UInt64 = 0
        for k in 0..<8 { mantissa = (mantissa << 8) | UInt64(d[o + 2 + k]) }
        guard mantissa != 0 else { return 0 }
        return Double(mantissa) * pow(2.0, Double(exp - 63))
    }
}
