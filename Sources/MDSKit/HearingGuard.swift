// HearingGuard.swift — 听力保护：由硬件音量衰减估算耳机声压级（纯函数）
//
// 背景：共享输出模式下软件拿不到真实声压（需要人工耳/耦合腔 + 校准麦克风），
// 但 DAC 的硬件音量衰减（CoreAudio VolumeDecibels）+ 耳机灵敏度/阻抗 +
// 输出口满幅电压（规格书）可以估算出稳态等效声压级，足够做听力防护提醒。
//
// 估算公式（1 kHz 稳态等效，非实测）：
//   V = 满幅电压 × 10^(音量dB / 20)          （音量 dB ≤ 0）
//   P[mW] = V² / 阻抗 × 1000
//   SPL = 灵敏度(dB/mW) + 10·log₁₀(P)
//
// 注意这是保守度有限的估算：音乐峰值会更高、录音响度差异大，
// 界面上必须标注「估算」，不能当作实测声压。

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
        /// 告警阈值（dB SPL）。NIOSH 8 小时职业限值 85 dB；更保守可设 80
        public var threshold: Double

        public init(sensitivity: Double = 108, impedance: Double = 32,
                    maxVrms: Double = 2.0, threshold: Double = 85) {
            self.sensitivity = sensitivity
            self.impedance = impedance
            self.maxVrms = maxVrms
            self.threshold = threshold
        }
    }

    /// 由当前音量衰减估算声压级（dB SPL）。
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

    /// 估算声压是否超过告警阈值（无法估算时视为未超）
    public static func exceedsThreshold(spl: Double?, params: Params) -> Bool {
        guard let spl else { return false }
        return spl > params.threshold
    }
}
