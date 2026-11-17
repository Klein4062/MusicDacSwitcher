// FormatMatcher.swift — 音源格式 → 设备能力 的匹配决策
//
// 匹配优先级：
//   采样率: 精确匹配 > 整数倍升频（设备 = k×源）> 整数倍降频 > 最近采样率
//   位深:   精确 > ≥ 源位深的最小整数位深 > 该采样率下最高整数位深 > 浮点
//   壬道:   源声道 > 2ch > 该采样率下支持的最大声道数

import CoreAudio
import Foundation

/// 位深策略
public enum BitDepthPolicy: Equatable {
    /// 该采样率下设备支持的最高整数位深（默认，DAC 表现通常最稳）
    case highest
    /// 尽量匹配源位深（选 ≥ 源的最小整数位深；不支持时向上/向下就近）
    case match(Int)
    /// 强制指定位深（不支持时回退到最高）
    case fixed(Int)
}

/// 匹配结果
public struct FormatMatch {
    public var asbd: AudioStreamBasicDescription
    public var reason: String
    public var exactRate: Bool
}

public enum FormatMatcher {

    /// 从能力列表中为目标（采样率/位深/声道）选出最佳物理格式
    public static func select(targetRate: Float64,
                       targetBits: Int?,
                       preferredChannels: Int? = 2,
                       entries: [PhysicalFormatEntry],
                       policy: BitDepthPolicy) -> FormatMatch? {
        guard !entries.isEmpty else { return nil }

        // 1. 采样率
        let ratePlan = resolveRate(targetRate: targetRate, entries: entries)
        var pool = ratePlan.pool
        let rate = ratePlan.rate
        var reason = ratePlan.reason
        let exactRate = ratePlan.exact
        if pool.isEmpty { return nil }

        // 2. 声道
        let channelSet = Set(pool.map(\.channels))
        let ch: Int
        if let p = preferredChannels, channelSet.contains(p) {
            ch = p
        } else if channelSet.contains(2) {
            ch = 2
        } else {
            ch = channelSet.max() ?? 2
        }
        pool = pool.filter { $0.channels == ch }
        if pool.isEmpty { return nil }

        // 3. 位深
        let ints = pool.filter(\.isSignedInteger).sorted { $0.bits < $1.bits }
        var chosen: PhysicalFormatEntry?
        if !ints.isEmpty {
            switch policy {
            case .highest:
                chosen = ints.last
                reason += " · 位深取最高 \(ints.last!.bits)bit"
            case .fixed(let b):
                if let e = ints.first(where: { $0.bits == b }) {
                    chosen = e
                    reason += " · 位深 \(b)bit（指定）"
                } else {
                    chosen = ints.last
                    reason += " · 不支持 \(b)bit，回退最高 \(ints.last!.bits)bit"
                }
            case .match(let b):
                if let e = ints.first(where: { $0.bits >= b }) {
                    chosen = e
                    reason += e.bits == b ? " · 位深精确 \(b)bit" : " · 位深向上适配 \(b)→\(e.bits)bit"
                } else {
                    chosen = ints.last
                    reason += " · 不支持 ≥\(b)bit，取最高 \(ints.last!.bits)bit"
                }
            }
        } else if let f = pool.filter(\.isFloat).max(by: { $0.bits < $1.bits }) {
            chosen = f
            reason += " · 无整数格式，用 \(f.bits)bit 浮点"
        }
        guard var entry = chosen else { return nil }

        // 4. 具体化采样率（连续区间设备需要把目标率写进 asbd）
        entry.asbd.mSampleRate = rate
        return FormatMatch(asbd: entry.asbd, reason: reason, exactRate: exactRate)
    }

    // MARK: - 采样率决策

    public struct RatePlan {
        public var pool: [PhysicalFormatEntry]
        public var rate: Float64
        public var reason: String
        public var exact: Bool
    }

    public static func resolveRate(targetRate: Float64, entries: [PhysicalFormatEntry]) -> RatePlan {
        // 精确匹配（含连续区间覆盖）
        let exactPool = entries.filter { $0.coversRate(targetRate) }
        if !exactPool.isEmpty {
            return RatePlan(pool: exactPool, rate: targetRate,
                            reason: "采样率精确 \(hz(targetRate))", exact: true)
        }

        // 设备支持的离散采样率点（连续区间的端点也算）
        var points = Set<Float64>()
        for e in entries {
            points.insert(e.rateMin)
            points.insert(e.rateMax)
        }
        let sorted = points.sorted()

        // 整数倍升频：设备率 = k × 目标率（如源 88.2k → 设备 176.4k）
        let ups = sorted.filter { isIntegerMultiple($0, of: targetRate) }
        if let up = ups.first {
            return plan(rate: up, entries: entries,
                        reason: "不支持 \(hz(targetRate))，整数倍升频 \(hz(up))", exact: false)
        }
        // 整数倍降频：目标率 = k × 设备率（最后手段之前）
        let downs = sorted.filter { isIntegerMultiple(targetRate, of: $0) }.sorted { $0 > $1 }
        if let down = downs.first {
            return plan(rate: down, entries: entries,
                        reason: "不支持 \(hz(targetRate))，整数倍降频 \(hz(down))", exact: false)
        }
        // 就近
        if let near = sorted.min(by: { abs($0 - targetRate) < abs($1 - targetRate) }) {
            return plan(rate: near, entries: entries,
                        reason: "不支持 \(hz(targetRate))，就近 \(hz(near))", exact: false)
        }
        return RatePlan(pool: [], rate: targetRate, reason: "无可用采样率", exact: false)
    }

    private static func plan(rate: Float64, entries: [PhysicalFormatEntry], reason: String, exact: Bool) -> RatePlan {
        RatePlan(pool: entries.filter { $0.coversRate(rate) }, rate: rate, reason: reason, exact: exact)
    }

    /// a 是否是 b 的整数倍（容差 0.5Hz，处理 44100/88200 之类）
    public static func isIntegerMultiple(_ a: Float64, of b: Float64) -> Bool {
        guard b > 0, a >= b else { return false }
        let k = (a / b).rounded()
        return k >= 2 && abs(a - k * b) < 0.5
    }

    /// 设备支持的全部采样率点（用于展示与降级决策）
    public static func supportedRates(entries: [PhysicalFormatEntry]) -> [Float64] {
        var points = Set<Float64>()
        for e in entries {
            points.insert(e.rateMin)
            points.insert(e.rateMax)
        }
        return points.sorted()
    }
}
