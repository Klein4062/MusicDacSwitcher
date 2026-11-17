// FormatController.swift — 评估当前状态并执行格式切换
//
// 切换采用"两步法"：
//   1) 若目标采样率 ≠ 当前采样率：先以现有位深为模板把采样率切过去
//      （DAC 在不同采样率下支持的位深列表不同，切换后需重新枚举）
//   2) 重新枚举该采样率下的可用格式，按策略选出最佳位深，再设置物理格式

import CoreAudio
import Foundation

public final class FormatController {
    /// 位深策略（GUI 可随时调整）
    public var policy: BitDepthPolicy
    public let dryRun: Bool
    public let verbose: Bool
    /// 总开关：关闭时不执行任何切换（GUI「自动切换」）
    public var enabled: Bool = true

    public init(policy: BitDepthPolicy = .highest, dryRun: Bool = false, verbose: Bool = false) {
        self.policy = policy
        self.dryRun = dryRun
        self.verbose = verbose
    }

    public func logV(_ msg: String) {
        if verbose { log("· \(msg)") }
    }

    /// watch 模式的入口：以设备当前标称采样率（系统已按播放内容切换）作为目标，
    /// 优化物理格式的位深/声道；hog 模式（播放器独占）时跳过
    public func evaluateAndApply(deviceID: AudioObjectID, context: String) {
        if let hog = AudioDevice.hogPID(deviceID), hog != -1 {
            logV("跳过：设备被 PID \(hog) 以 hog 模式独占（播放器自行管理格式）· \(context)")
            return
        }
        guard let streamID = AudioDevice.outputStreams(deviceID).first else {
            logV("设备无输出流 · \(context)")
            return
        }
        guard let nominal = AudioDevice.nominalRate(deviceID) else {
            logV("读取不到标称采样率 · \(context)")
            return
        }
        applyBestFormat(deviceID: deviceID, streamID: streamID,
                        desiredRate: nominal, context: context)
    }

    /// 把流切换到 desiredRate（可降级）下的最佳物理格式。
    /// 返回最终生效的格式描述（失败返回 nil）。
    @discardableResult
    public func applyBestFormat(deviceID: AudioObjectID,
                         streamID: AudioObjectID,
                         desiredRate: Float64,
                         sourceBits: Int? = nil,
                         channels: Int? = 2,
                         context: String) -> AudioStreamBasicDescription? {
        guard let current = AudioDevice.streamPhysicalFormat(streamID) else {
            log("读取当前物理格式失败 · \(context)")
            return nil
        }
        let virtualRanges = AudioDevice.streamAvailableVirtualRanges(streamID)
        let currentEntries = AudioDevice.streamAvailablePhysicalFormats(streamID)

        let effectivePolicy: BitDepthPolicy
        if case .highest = policy, let sb = sourceBits {
            effectivePolicy = .match(sb)
        } else {
            effectivePolicy = policy
        }

        // ── dry-run：不真正切换，用当前能力 + 虚拟采样率范围做预测 ──
        if dryRun {
            let candidates = collectAllRates(from: virtualRanges, entriesAtCurrentRate: currentEntries)
            guard let best = FormatMatcher.select(targetRate: desiredRate,
                                                  targetBits: sourceBits,
                                                  preferredChannels: channels,
                                                  entries: candidates,
                                                  policy: effectivePolicy) else {
                log("设备不支持 \(hz(desiredRate))，且无法选出替代格式 · \(context)")
                return nil
            }
            if sameFormat(current, best.asbd) {
                log("已是最佳格式：\(describe(current)) · \(context)")
                return current
            }
            log("[dry-run] 将设置 \(describe(best.asbd)) （\(best.reason)）· \(context)")
            return best.asbd
        }

        // ── 决策目标采样率（不支持时降级）──
        let rateSupported = virtualRanges.isEmpty || virtualRanges.contains { $0.min <= desiredRate && $0.max >= desiredRate }
        let targetRate: Float64
        if rateSupported {
            targetRate = desiredRate
        } else {
            let candidates = collectAllRates(from: virtualRanges, entriesAtCurrentRate: currentEntries)
            let fallback = FormatMatcher.resolveRate(targetRate: desiredRate, entries: candidates)
            guard !fallback.pool.isEmpty else {
                log("设备不支持 \(hz(desiredRate))，且无法选出替代采样率 · \(context)")
                return nil
            }
            log("⚠️ 设备不支持 \(hz(desiredRate)) → \(fallback.reason) · \(context)")
            targetRate = fallback.rate
        }

        // ── 第 1 步：必要时先切采样率（位深沿用当前模板）──
        if current.mSampleRate != targetRate {
            logV("目标 \(hz(targetRate)) · 当前 \(hz(current.mSampleRate)) · \(context)")
            if !stepSwitchRate(streamID: streamID, current: current, to: targetRate, context: context) {
                return nil
            }
        }

        // ── 第 2 步：在目标采样率下选最佳位深（重新枚举，不同采样率支持的位深不同）──
        let entries = AudioDevice.streamAvailablePhysicalFormats(streamID)
        guard let best = FormatMatcher.select(targetRate: targetRate,
                                              targetBits: sourceBits,
                                              preferredChannels: channels,
                                              entries: entries,
                                              policy: effectivePolicy) else {
            log("设备未报告可用格式，无法决策 · \(context)")
            return nil
        }

        // 幂等检查用最新的格式（第 1 步可能已切换采样率）
        let nowFormat = AudioDevice.streamPhysicalFormat(streamID) ?? current
        if sameFormat(nowFormat, best.asbd) {
            logV("已是最佳格式：\(describe(nowFormat)) · \(context)")
            return nowFormat
        }

        guard apply(streamID: streamID, asbd: best.asbd,
                    note: best.reason, context: context) else { return nil }

        if let verify = AudioDevice.streamPhysicalFormat(streamID) {
            if !sameFormat(verify, best.asbd) {
                log("⚠️ 设备回读格式与目标不一致：\(describe(verify))（部分驱动不支持部分格式组合）")
            }
            return verify
        }
        return best.asbd
    }

    // MARK: - 内部

    /// 只切采样率：以当前格式为模板改采样率直接设置物理格式
    private func stepSwitchRate(streamID: AudioObjectID,
                                current: AudioStreamBasicDescription,
                                to rate: Float64,
                                context: String) -> Bool {
        var step = current
        step.mSampleRate = rate
        return apply(streamID: streamID, asbd: step,
                     note: "先切采样率 → \(hz(rate))", context: context)
    }

    private func apply(streamID: AudioObjectID,
                       asbd: AudioStreamBasicDescription,
                       note: String,
                       context: String) -> Bool {
        if dryRun {
            log("[dry-run] 将设置 \(describe(asbd)) （\(note)）· \(context)")
            return true
        }
        do {
            try AudioDevice.setStreamPhysicalFormat(streamID, asbd)
            // CoreAudio 提交物理格式后是异步生效的：等待设备真正切换完成，
            // 否则后续枚举/回读会拿到旧采样率下的信息
            if waitForFormat(streamID: streamID, target: asbd, timeoutMS: 800) {
                log("已切换 → \(describe(asbd)) （\(note)）· \(context)")
            } else {
                let actual = AudioDevice.streamPhysicalFormat(streamID).map(describe) ?? "?"
                log("已提交 \(describe(asbd))，但等待生效超时（当前 \(actual)）· \(context)")
            }
            return true
        } catch {
            log("切换失败：\(error) · 目标 \(describe(asbd)) · \(context)")
            return false
        }
    }

    /// 轮询等待物理格式真正变更为目标值（属性 set 返回 noErr 不代表立即生效）
    private func waitForFormat(streamID: AudioObjectID,
                               target: AudioStreamBasicDescription,
                               timeoutMS: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000.0)
        while Date() < deadline {
            if let cur = AudioDevice.streamPhysicalFormat(streamID), sameFormat(cur, target) {
                return true
            }
            usleep(20_000)
        }
        return AudioDevice.streamPhysicalFormat(streamID).map { sameFormat($0, target) } ?? false
    }

    /// 用虚拟格式范围 + 当前采样率下的实体条目，拼出覆盖全部采样率的候选集合
    private func collectAllRates(from ranges: [(min: Float64, max: Float64)],
                                 entriesAtCurrentRate: [PhysicalFormatEntry]) -> [PhysicalFormatEntry] {
        var result = entriesAtCurrentRate
        for r in ranges where r.min != r.max {
            // 连续区间：构造占位条目（位深集合沿用当前，仅用于采样率决策）
            if let template = entriesAtCurrentRate.first {
                var e = template
                e.rateMin = r.min
                e.rateMax = r.max
                result.append(e)
            }
        }
        return result
    }
}
