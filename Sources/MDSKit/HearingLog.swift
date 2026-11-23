// HearingLog.swift — 听力暴露历史与周剂量（WHO H.870 口径）
//
// 周剂量：以 80 dB LAeq × 40 小时/周 为 100% 额度，能量等效（3 dB 交换率，
// 每 +3 dB 安全时长减半）。例：90 dB 听 1h = 10 等效小时 = 25% 周额度。
// 声压来自估算（设备音量 × 耳机参数 × 实测曲目电平），非实测——剂量同口径。
//
// 存储：JSONL，每 5 分钟一桶落一行 {"t":epoch, "s":活跃秒, "l":桶内能量平均dB}，
// 只记录播放中的暴露。滚动窗口最近 7 天聚合（非自然周，避免周一清零错觉）。
// 崩溃最多丢当前桶（≤5 分钟）。

import Foundation

public final class HearingLog {

    /// 周剂量结果
    public struct Dose: Equatable {
        /// 相对 80dB×40h 基准的百分比（可 >100）
        public let percent: Double
        /// 折算到 80dB 的等效小时数
        public let equivalentHours: Double
        /// 窗口内实际播放小时数
        public let activeHours: Double
    }

    /// 落盘条目：桶起点 / 活跃秒数 / 桶内能量平均声压
    public struct Entry: Codable, Equatable {
        public let t: TimeInterval   // epoch 秒
        public let s: Double         // 活跃秒
        public let l: Double         // 平均 dB
    }

    public static let defaultURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MusicDacSwitcher", isDirectory: true)
        return dir.appendingPathComponent("hearing.jsonl")
    }()

    /// 基准：80 dB × 40 h/周 = 100%（WHO-ITU H.870 个人音频设备口径）
    public static let referenceDB: Double = 80
    public static let referenceHours: Double = 40

    private let url: URL
    private let bucketLength: TimeInterval = 300
    /// 串行队列：落盘与加载不占主线程
    private let ioQueue = DispatchQueue(label: "mds.hearing.log", qos: .utility)

    // 当前未落盘的桶（主线程访问）
    private var bucketStart: Date?
    private var bucketEnergySec: Double = 0   // Σ 10^(L/10)·dt（线性能量·秒）
    private var bucketSeconds: Double = 0

    /// 桶落盘后回调（主线程）：供 UI 重算滚动剂量
    public var onFlush: (() -> Void)?

    public init(url: URL = HearingLog.defaultURL) {
        self.url = url
    }

    // MARK: - 记录（主线程，2s 轮询驱动）

    /// 记录一次采样。仅播放中且有估算声压时累计暴露；
    /// 桶跨过 5 分钟边界即落盘（同步返回，写盘走 ioQueue）。
    public func record(avgSPL: Double?, playing: Bool, at date: Date = Date()) {
        guard playing, let spl = avgSPL, spl.isFinite else { return }
        if bucketStart == nil { bucketStart = date }
        bucketEnergySec += pow(10, spl / 10) * 2   // 采样周期 2s
        bucketSeconds += 2
        if date.timeIntervalSince(bucketStart!) >= bucketLength {
            flush(at: date)
        }
    }

    /// 把当前桶落盘并重置（应用退出前调用可少丢数据）
    public func flush(at date: Date = Date()) {
        guard let start = bucketStart else { return }
        let energy = bucketEnergySec
        let secs = bucketSeconds
        bucketStart = date
        bucketEnergySec = 0
        bucketSeconds = 0
        guard secs >= 5, energy > 0 else { return } // 过短的噪声桶丢弃
        let entry = Entry(t: start.timeIntervalSince1970, s: secs,
                          l: 10 * log10(energy / secs))
        ioQueue.async { [url] in
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            try? (line + "\n").data(using: .utf8)?.append(to: url)
        }
        onFlush?()
    }

    // MARK: - 剂量计算（纯函数，自测覆盖）

    /// 滚动窗口内条目的周剂量。能量等效：t_eq = Σ s·10^((l−80)/10)。
    public static func weeklyDose(entries: [Entry], now: Date,
                                  window: TimeInterval = 7 * 86400,
                                  referenceDB: Double = HearingLog.referenceDB,
                                  referenceHours: Double = HearingLog.referenceHours) -> Dose? {
        let cutoff = now.timeIntervalSince1970 - window
        var eqSec = 0.0, activeSec = 0.0
        for e in entries where e.t > cutoff {
            eqSec += e.s * pow(10, (e.l - referenceDB) / 10)
            activeSec += e.s
        }
        guard activeSec > 0 else { return nil }
        let eqHours = eqSec / 3600
        return Dose(percent: eqHours / referenceHours * 100,
                    equivalentHours: eqHours,
                    activeHours: activeSec / 3600)
    }

    /// 读取存储文件解析条目（坏行跳过），供剂量计算与展示
    public static func loadEntries(from url: URL = HearingLog.defaultURL) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(Entry.self, from: data)
        }
    }

    /// 便捷：当前存储的滚动 7 天剂量
    public static func weeklyDose(fromFile url: URL = HearingLog.defaultURL,
                                  now: Date = Date()) -> Dose? {
        weeklyDose(entries: loadEntries(from: url), now: now)
    }

    /// 剩余额度在给定声压下的可听小时数（能量等效反解）：
    /// 剩余等效小时 × 10^((80−L)/10)。avgSPL 为 nil 时按 80dB 基准口径；
    /// 低于 80dB 时可听时长按 3dB 一倍放大。无剂量记录 → nil。
    public static func remainingHours(dose: Dose?, avgSPL: Double?) -> Double? {
        guard let dose else { return nil }
        let remainEq = max(0, 1 - dose.percent / 100) * referenceHours
        guard let avg = avgSPL, avg.isFinite else { return remainEq }
        return remainEq * pow(10, (referenceDB - avg) / 10)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(self)
    }
}
