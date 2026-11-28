// HearingProfile.swift — 耳机档案：按输出设备自动切换听力保护参数
//
// 场景：同一副 Mac 接不同的前端/耳机（如 TP55+平板耳机、USB-C 数字
// 直连主动耳机、蓝牙dongle），灵敏度/阻抗/满幅电压完全不同，手填
// 参数容易忘改导致声压估算系统性偏差。每个档案绑定一组设备名关键词，
// 输出设备切换时自动套用。
//
// 注意：纯数字主动耳机（无模拟输入，如 Sennheiser HDB 630：USB-C
// 数字输入，THD 0.2% @105 dB SPL）没有电压→功率→声压链路，建模为
// 「满幅声压 + 数字音量衰减」：等效 imp=1Ω、vrms=1V、sens=满幅声压−30
// （1V/1Ω = 1000mW = +30dB re 1mW），例：满幅 ≈110 dB → sens=80。

import Foundation

public struct HearingProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    /// 显示名（如 "TP55 · 彼岸银翼"）
    public var name: String
    /// 设备名匹配关键词（不区分大小写，包含即命中；如 ["tp55"]）
    public var matchKeywords: [String]
    /// 耳机灵敏度（dB/mW）
    public var sensDB: Double
    /// 耳机阻抗（Ω）
    public var impOhm: Double
    /// 输出口满幅电压（Vrms）
    public var maxVrms: Double
    /// 机身音量旋钮衰减（dB，≤0）
    public var attenDB: Double

    public init(id: UUID = UUID(), name: String, matchKeywords: [String],
                sensDB: Double, impOhm: Double, maxVrms: Double, attenDB: Double) {
        self.id = id
        self.name = name
        self.matchKeywords = matchKeywords
        self.sensDB = sensDB
        self.impOhm = impOhm
        self.maxVrms = maxVrms
        self.attenDB = attenDB
    }

    /// 按设备名（含厂商名，如 "TP55 — Topping"）匹配档案：首个关键词
    /// 命中者胜（列表顺序即优先级）。设备名空/无档案 → nil。
    public static func match(_ profiles: [HearingProfile],
                             deviceName: String?) -> HearingProfile? {
        guard let name = deviceName?.lowercased(), !name.isEmpty else { return nil }
        return profiles.first { p in
            p.matchKeywords.contains {
                let kw = $0.trimmingCharacters(in: .whitespaces).lowercased()
                return !kw.isEmpty && name.contains(kw)
            }
        }
    }

    /// 是否阻断估算：自动跟随开启、当前设备无匹配档案、且用户未手动选
    /// 档案时，参数无从校准（外放音箱/未建档输出）——按残留的耳机参数
    /// 瞎猜会严重失真（实测外放挂耳机档案冒出 100dB+ 暴露条目）。
    /// 宁缺毋错：不估算、不累计剂量。有选中档案（含手动选，用户意图
    /// 优先）或关闭跟随（手动模式自负）则可估算。
    public static func estimationBlocked(profiles: [HearingProfile], deviceName: String?,
                                         autoFollow: Bool, hasActiveProfile: Bool) -> Bool {
        guard autoFollow, !hasActiveProfile else { return false }
        return match(profiles, deviceName: deviceName) == nil
    }
}
