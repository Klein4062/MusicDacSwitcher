// HearingGuard.swift — 听力保护：由硬件音量衰减估算耳机声压级（纯函数）
//
// 背景：共享输出模式下软件拿不到真实声压（需要人工耳/耦合腔 + 校准麦克风），
// 但 DAC 的硬件音量衰减（CoreAudio VolumeDecibels）+ 耳机灵敏度/阻抗 +
// 输出口满幅电压（规格书）可以估算出稳态等效声压级，足够做听力防护提醒。
//
// 估算公式（1 kHz 满幅正弦等效，非实测）：
//   V = 满幅电压 × 10^(音量dB / 20)          （音量 dB ≤ 0）
//   P[mW] = V² / 阻抗 × 1000
//   SPL_peak = 灵敏度(dB/mW) + 10·log₁₀(P)
//   SPL_avg  = SPL_peak − 音乐峰值因子（crest factor）
//
// 双口径：SPL_peak 是「满幅正弦等效」= 峰值上限；真实音乐的平均 RMS
// 比满幅正弦低一个峰值因子（流行 ~12 dB、古典 ~18 dB）。听力标准的
// 85 dB 对应平均声压（LAeq），因此告警对平均口径判定。
// 另注意 DAC 机身增益档（模拟域）改变满幅基准，macOS 感知不到，
// 需要在界面把「满幅电压」参数跟随当前增益档（如 TP55：高 4.2 / 低 2.1 Vrms）。

import Foundation

public enum HearingGuard {

    /// 估算参数（GUI 可调，持久化）
    public struct Params: Equatable {
        /// 耳机灵敏度（dB/mW @ 1kHz），典型入耳式 105~112
        public var sensitivity: Double
        /// 耳机阻抗（Ω），典型入耳式 16~32
        public var impedance: Double
        /// 输出口满幅输出电压（Vrms），查 DAC/耳放规格（3.5mm 单端常见 ~2V，4.4mm 平衡 ~4V）
        public var maxVrms: Double
        /// 告警阈值（dB SPL，平均口径）。NIOSH 8 小时职业限值 85 dB；更保守可设 80
        public var threshold: Double
        /// 音乐峰值因子（dB）：峰值与平均 RMS 的差，流行 ~12、古典 ~18、纯音测试 0。
        /// 告警与显示的平均声压按此从峰值口径折算
        public var crestDB: Double

        public init(sensitivity: Double = 108, impedance: Double = 32,
                    maxVrms: Double = 2.0, threshold: Double = 85,
                    crestDB: Double = 12) {
            self.sensitivity = sensitivity
            self.impedance = impedance
            self.maxVrms = maxVrms
            self.threshold = threshold
            self.crestDB = crestDB
        }
    }

    /// 由当前音量衰减估算峰值口径声压（满幅正弦等效，dB SPL）。
    /// volumeDB 为设备相对满幅的衰减（≤0）；静音/无音量信息/参数非法 → nil。
    public static func estimatedSPL(volumeDB: Double?, params: Params) -> Double? {
        guard let db = volumeDB, db > -200 else { return nil }
        guard params.impedance > 0, params.maxVrms > 0 else { return nil }
        let clamped = max(db, -120) // 极低音量下避免下溢，钳到 -120 dB
        let volts = params.maxVrms * pow(10.0, clamped / 20)
        guard volts > 0 else { return nil }
        let milliwatts = volts * volts / params.impedance * 1000
        return params.sensitivity + 10 * log10(milliwatts)
    }

    /// 平均口径声压（≈ LAeq 等效）= 峰值 − 音乐峰值因子；峰值未知 → nil
    public static func averageSPL(peakSPL: Double?, params: Params) -> Double? {
        guard let peakSPL else { return nil }
        return peakSPL - params.crestDB
    }

    /// 估算声压是否超过告警阈值。对**平均口径**判定（听力限值是 LAeq 口径）；
    /// 无法估算时视为未超。
    public static func exceedsThreshold(spl: Double?, params: Params) -> Bool {
        guard let avg = averageSPL(peakSPL: spl, params: params) else { return false }
        return avg > params.threshold
    }
}
