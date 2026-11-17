// SelfTest.swift — 匹配算法自测（mds selftest，不依赖 XCTest，任何环境可跑）

import CoreAudio
import Foundation

// MARK: - 测试用格式构造

private func entry(rate: Float64, bits: UInt32, channels: UInt32 = 2, isFloat: Bool = false) -> PhysicalFormatEntry {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = rate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = isFloat
        ? kAudioFormatFlagIsFloat
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
    asbd.mChannelsPerFrame = channels
    asbd.mBitsPerChannel = bits
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerFrame = channels * bits / 8
    asbd.mBytesPerPacket = asbd.mBytesPerFrame
    return PhysicalFormatEntry(AudioStreamRangedDescription(
        mFormat: asbd,
        mSampleRateRange: AudioValueRange(mMinimum: rate, mMaximum: rate)))
}

/// 模拟类似 TP55 的 DAC：44.1 系 + 48 系全档，16/24/32bit 整数
private let tp55: [PhysicalFormatEntry] = {
    var e: [PhysicalFormatEntry] = []
    for rate: Float64 in [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000] {
        for bits: UInt32 in [16, 24, 32] {
            e.append(entry(rate: rate, bits: bits))
        }
    }
    return e
}()

/// 模拟仅支持 32k/48k/96k、16/20/24bit 的老 DAC（类似 LEN T27q）
private let legacy48: [PhysicalFormatEntry] = {
    var e: [PhysicalFormatEntry] = []
    for rate: Float64 in [32000, 48000, 96000] {
        for bits: UInt32 in [16, 20, 24] {
            e.append(entry(rate: rate, bits: bits))
        }
    }
    return e
}()

// MARK: - 断言工具

private var passCount = 0
private var failCount = 0

private func expect(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond {
        passCount += 1
        print("  ✓ \(name)")
    } else {
        failCount += 1
        print("  ✗ \(name) \(detail())")
    }
}

// MARK: - 用例

public func runSelfTest() {
    print("FormatMatcher 自测")

    // 精确匹配 · 最高位深
    do {
        let m = FormatMatcher.select(targetRate: 192000, targetBits: nil, entries: tp55, policy: .highest)
        expect("192k 精确匹配取最高 32bit", m?.asbd.mSampleRate == 192000 && m?.asbd.mBitsPerChannel == 32)
        expect("192k 标记为精确匹配", m?.exactRate == true)
    }
    do {
        let m = FormatMatcher.select(targetRate: 768000, targetBits: nil, entries: tp55, policy: .highest)
        expect("768k 取 32bit", m?.asbd.mBitsPerChannel == 32 && m?.asbd.mSampleRate == 768000)
    }
    // 位深匹配策略
    do {
        let m = FormatMatcher.select(targetRate: 44100, targetBits: 20, entries: tp55, policy: .match(20))
        expect("源 20bit → ≥20 的最小 24bit", m?.asbd.mBitsPerChannel == 24 && m?.asbd.mSampleRate == 44100)
    }
    do {
        let m = FormatMatcher.select(targetRate: 44100, targetBits: 16, entries: tp55, policy: .match(16))
        expect("源 16bit 精确匹配 16bit", m?.asbd.mBitsPerChannel == 16)
    }
    do {
        let m = FormatMatcher.select(targetRate: 48000, targetBits: nil, entries: legacy48, policy: .fixed(32))
        expect("强制 32bit 但设备最高 24 → 回退 24bit", m?.asbd.mBitsPerChannel == 24)
    }
    do {
        // 源 32bit（如 DSD 转 PCM 高位深），老 DAC 最高 24 → 向下降级
        let m = FormatMatcher.select(targetRate: 48000, targetBits: 32, entries: legacy48, policy: .match(32))
        expect("源 32bit 设备最高 24 → 取 24bit", m?.asbd.mBitsPerChannel == 24)
    }
    // 采样率降级
    do {
        let m = FormatMatcher.select(targetRate: 44100, targetBits: nil, entries: legacy48, policy: .highest)
        expect("44.1k 在仅 48 系设备上 → 就近 48k", m?.asbd.mSampleRate == 48000 && m?.exactRate == false)
    }
    do {
        let device = [entry(rate: 48000, bits: 24), entry(rate: 88200, bits: 24)]
        let m = FormatMatcher.select(targetRate: 44100, targetBits: nil, entries: device, policy: .highest)
        expect("44.1k 无精确但 88.2k 为整数倍 → 升频 88.2k", m?.asbd.mSampleRate == 88200)
    }
    do {
        // 源 88.2k，设备仅 44.1/48：88.2 = 2×44.1 → 整数倍降频选 44.1（而非就近 48）
        let device = [entry(rate: 44100, bits: 24), entry(rate: 48000, bits: 24)]
        let m = FormatMatcher.select(targetRate: 88200, targetBits: nil, entries: device, policy: .highest)
        expect("88.2k → 整数分频 44.1k 优先于就近 48k", m?.asbd.mSampleRate == 44100)
    }
    do {
        let device = [entry(rate: 48000, bits: 24), entry(rate: 96000, bits: 24)]
        let m = FormatMatcher.select(targetRate: 50000, targetBits: nil, entries: device, policy: .highest)
        expect("50k 无整数关系 → 就近 48k", m?.asbd.mSampleRate == 48000)
    }
    // 浮点设备（内置扬声器类）
    do {
        let builtin = [entry(rate: 44100, bits: 32, isFloat: true),
                       entry(rate: 48000, bits: 32, isFloat: true)]
        let m = FormatMatcher.select(targetRate: 44100, targetBits: 16, entries: builtin, policy: .match(16))
        expect("浮点设备回退 32bit float", m?.asbd.mSampleRate == 44100
            && m?.asbd.mBitsPerChannel == 32
            && m!.asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }
    // 声道
    do {
        var device = tp55
        device.append(entry(rate: 96000, bits: 24, channels: 8))
        let m = FormatMatcher.select(targetRate: 96000, targetBits: nil, preferredChannels: 2,
                                     entries: device, policy: .highest)
        expect("存在多声道条目时仍选 2ch", m?.asbd.mChannelsPerFrame == 2)
    }
    // 整数倍判断
    expect("88200 是 44100 的整数倍", FormatMatcher.isIntegerMultiple(88200, of: 44100))
    expect("48000 不是 44100 的整数倍", !FormatMatcher.isIntegerMultiple(48000, of: 44100))
    expect("44100 不是 88200 的整数倍（小数为大）", !FormatMatcher.isIntegerMultiple(44100, of: 88200))

    // 连续采样率设备
    do {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 48000
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = 2
        asbd.mBitsPerChannel = 32
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = 8
        asbd.mBytesPerPacket = 8
        let continuous = [PhysicalFormatEntry(AudioStreamRangedDescription(
            mFormat: asbd,
            mSampleRateRange: AudioValueRange(mMinimum: 8000, mMaximum: 768000)))]
        var allOK = true
        for rate: Float64 in [44100, 44300, 192000, 705600] {
            let m = FormatMatcher.select(targetRate: rate, targetBits: nil, entries: continuous, policy: .highest)
            if m?.asbd.mSampleRate != rate { allOK = false }
        }
        expect("连续采样率设备支持任意率（含 44.3k 等非标率）", allOK)
    }

    // 空能力
    expect("空能力列表返回 nil", FormatMatcher.select(targetRate: 44100, targetBits: nil, entries: [], policy: .highest) == nil)

    // 源探测：文件头解析
    do {
        let tmp = FileManager.default.temporaryDirectory
        // 构造 44 字节 WAV 头（48k/16bit/2ch）
        var wav = Data()
        func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) -> Data { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }
        wav.append(Data("RIFF".utf8)); wav.append(le32(36)); wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8)); wav.append(le32(16))
        wav.append(le16(1)); wav.append(le16(2)); wav.append(le32(48000))
        wav.append(le32(48000 * 4)); wav.append(le16(4)); wav.append(le16(16))
        wav.append(Data("data".utf8)); wav.append(le32(0))
        let wavURL = tmp.appendingPathComponent("mds-selftest.wav")
        try? wav.write(to: wavURL)
        let p1 = SourceProbe.parseHeader(wavURL.path)
        expect("WAV 头解析 48k/16bit/2ch", p1?.sampleRate == 48000 && p1?.bitsPerSample == 16 && p1?.channels == 2)

        // 构造 FLAC STREAMINFO（96k/24bit/2ch）
        var flac = Data("fLaC".utf8)
        flac.append(0x00)                       // 非最后块 | type 0 = STREAMINFO
        flac.append(contentsOf: [0, 0, 34])     // 块长 34
        flac.append(contentsOf: [UInt8](repeating: 0, count: 10)) // min/max blocksize/framesize
        var v: UInt64 = (UInt64(96000) << 44) | (1 << 41) | (23 << 36) // rate=96000 ch=2 bits=24
        var field = Data()
        for shift in stride(from: 56, through: 0, by: -8) { field.append(UInt8((v >> UInt64(shift)) & 0xFF)) }
        flac.append(field)
        flac.append(contentsOf: [UInt8](repeating: 0, count: 16)) // md5 占位
        let flacURL = tmp.appendingPathComponent("mds-selftest.flac")
        try? flac.write(to: flacURL)
        let p2 = SourceProbe.parseHeader(flacURL.path)
        expect("FLAC 头解析 96k/24bit/2ch", p2?.sampleRate == 96000 && p2?.bitsPerSample == 24 && p2?.channels == 2)
    }

    // 源探测：正在播放文件识别（offset 前进检测）
    do {
        func f(_ path: String, _ rate: Float64, _ offset: UInt64?) -> SourceProbe.Probe {
            SourceProbe.Probe(path: path, sampleRate: rate, bitsPerSample: 16,
                              channels: 2, kind: "FLAC", pid: 1, offset: offset)
        }
        // 场景：播放 44.1k 文件（offset 前进），残留 192k 句柄停滞 → 必须选 44.1k
        let a = [f("/m/hi.flac", 192000, 548_680), f("/m/cur.flac", 44100, 16_384)]
        let b = [f("/m/hi.flac", 192000, 548_680), f("/m/cur.flac", 44100, 98_304)]
        let picked = SourceProbe.pickPlaying(a: a, b: b)
        expect("前进的 44.1k 文件胜过停滞的 192k 残留", picked?.path == "/m/cur.flac")
        // 多个前进：读取量最大者优先
        let c = [f("/m/x.flac", 96000, 100), f("/m/y.flac", 48000, 100)]
        let d = [f("/m/x.flac", 96000, 300), f("/m/y.flac", 48000, 90_000)]
        expect("多个前进时选前进量最大者", SourceProbe.pickPlaying(a: c, b: d)?.path == "/m/y.flac")
        // 全部停滞 → nil（残留不可信）
        let e = [f("/m/hi.flac", 192000, 548_680)]
        expect("全部停滞返回 nil（不误信残留）", SourceProbe.pickPlaying(a: e, b: e) == nil)
        // 完全无 offset 信息 → 回退采样率最高
        let g = [f("/m/a.flac", 44100, nil), f("/m/b.flac", 96000, nil)]
        expect("无 offset 信息回退采样率最高", SourceProbe.pickPlaying(a: [], b: g)?.path == "/m/b.flac")
        // offset 解析
        expect("lsof offset \"0t548680\" 解析", SourceProbe.parseOffset("0t548680") == 548_680)
        expect("lsof offset \"548680\" 解析", SourceProbe.parseOffset("548680") == 548_680)
        expect("lsof offset \"0x10\" 拒绝", SourceProbe.parseOffset("0x10") == nil)
        // 空集
        expect("空扫描返回 nil", SourceProbe.pickPlaying(a: [], b: []) == nil)
    }

    print()
    print("结果: \(passCount) 通过, \(failCount) 失败")
    if failCount > 0 { exit(1) }
}
