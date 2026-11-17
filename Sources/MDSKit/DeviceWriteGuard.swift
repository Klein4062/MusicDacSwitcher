// DeviceWriteGuard.swift — 设备写入保护（纯逻辑，可自测）
//
// 两类保护，解决「设备刚连上就被切格式打掉」和「反复切掉设备」：
//
//   1. 稳定期（settle）：设备（重新）绑定 / 刚出现后的一段时间内不写格式。
//      部分 USB DAC 在枚举完成、时钟同步尚未稳定时被改格式，
//      会因带宽重新协商失败而掉线。
//
//   2. 熔断（circuit breaker）：若我们写入格式后设备很快从系统消失，
//      判定为「切换导致掉线」；连续达到阈值即进入稳定（只读）模式，
//      不再自动写设备，直到用户显式恢复。
//
// 全部基于注入的时间点，不依赖真实时钟与硬件，便于自测。

import Foundation

public struct DeviceWriteGuard {
    /// 设备绑定后的稳定期（秒）
    public var settleSeconds: Double
    /// 写入格式后设备在此窗口内消失 → 记为一次「切换导致掉线」
    public var faultWindow: Double
    /// 连续故障达到该值 → 进入稳定（只读）模式
    public var faultThreshold: Int

    /// 稳定期截止时间
    public private(set) var settleUntil: Date
    /// 最近一次「真正改动了格式」的时间
    public private(set) var lastWrite: Date?
    /// 连续故障次数
    public private(set) var faults: Int = 0
    /// 稳定（只读）模式
    public private(set) var passive: Bool = false

    public init(settleSeconds: Double = 8,
                faultWindow: Double = 20,
                faultThreshold: Int = 2,
                now: Date = Date()) {
        self.settleSeconds = settleSeconds
        self.faultWindow = faultWindow
        self.faultThreshold = faultThreshold
        self.settleUntil = now.addingTimeInterval(settleSeconds)
    }

    /// 设备（重新）绑定：重新进入稳定期
    public mutating func noteBound(at now: Date) {
        settleUntil = now.addingTimeInterval(settleSeconds)
    }

    /// 当前是否允许写设备（稳定期外且未熔断）
    public func canWrite(at now: Date) -> Bool {
        !passive && now >= settleUntil
    }

    /// 记录一次真实写操作
    public mutating func noteWrite(at now: Date) {
        lastWrite = now
    }

    /// 设备从系统消失。返回是否因此刚进入稳定（只读）模式。
    /// 只有「写入后 faultWindow 内消失」才归咎于我们的切换。
    @discardableResult
    public mutating func noteVanished(at now: Date) -> Bool {
        guard let last = lastWrite, now.timeIntervalSince(last) <= faultWindow else {
            return false
        }
        lastWrite = nil // 一次写入只归咎一次
        faults += 1
        if !passive, faults >= faultThreshold {
            passive = true
            return true
        }
        return false
    }

    /// 用户显式恢复：清空故障计数并重新进入稳定期
    public mutating func reset(at now: Date) {
        passive = false
        faults = 0
        lastWrite = nil
        settleUntil = now.addingTimeInterval(settleSeconds)
    }
}
