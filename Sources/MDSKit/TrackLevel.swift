// TrackLevel.swift — 曲目电平分析：解码音频文件算平均 RMS / 峰值（dBFS）
//
// 用途：听力保护估算的「平均口径」需要曲目实际电平——满幅假设
// （0 dBFS）比真实音乐平均 RMS 高 10~20 dB（古典 −22 左右、响度战争
// 流行 −8 左右），录音电平差异是估算最大的系统性偏差。源探测已经
// 知道正在播放哪个文件，这里按 path 解码实测。
//
// 分片聚合：部分播放器（Sony Music Center）把曲库切成 ~10s 的编号
// 分片缓存（<曲目ID>/001.flac、002.flac…），只看单片会让"全曲平均"
// 退化为 10 秒片电平、分段表只有一段（「此刻」恒等于「平均」）。
// 检测到编号分片组时自动聚合同组全部文件：跨片累积分段表，
// fileSize=总字节；播放位置换算成全局偏移后按段取「此刻」。
//
// 限制：DSF/DSD 与加密缓存（.uc!、.mflac）CoreAudio 解不了 → 返回
// nil，调用方回退静态峰值因子参数。分析在后台线程调用；结果按
// 组 key + 最大修改时间缓存（同一文件不重复解码）。

import Foundation
import AudioToolbox

public enum TrackLevelAnalyzer {

    public struct Result: Equatable {
        /// 全文件（或全分片组）平均 RMS（dBFS，≤ 0）
        public let rmsDB: Double
        /// 全文件真峰值近似（dBFS，≤ 0）
        public let peakDB: Double
        /// 总时长（秒）
        public let durationSec: Double
        /// 分段长度（秒，固定 10）
        public let segmentSec: Double
        /// 按播放顺序的分段 RMS（dBFS），供「此刻声压」按位置取用
        public let segments: [Double]
        /// 总字节数（配合全局偏移估算播放位置）
        public let fileSize: UInt64
    }

    /// 分析结果缓存（线程安全；进程内存级，重启即清）
    private static let cache = NSCache<NSString, Box>()

    private final class Box: NSObject {
        let mtime: TimeInterval
        let result: Result
        init(mtime: TimeInterval, result: Result) {
            self.mtime = mtime
            self.result = result
        }
    }

    // MARK: - 分片组

    /// 检测 path 是否属于编号分片组（"NNN.ext"，同目录 ≥2 个兄弟分片）。
    /// 返回按序号排序的组内完整路径（含自身）；非分片 → nil。
    /// 3 位纯数字文件名在普通目录偶见，要求 ≥2 个才成组，尽量不误伤。
    static func shardGroup(_ path: String) -> [String]? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent
        guard !ext.isEmpty, stem.count == 3, stem.allSatisfy(\.isNumber) else { return nil }
        let dir = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let siblings = names
            .filter { n in
                let s = (n as NSString).deletingPathExtension
                let e = (n as NSString).pathExtension.lowercased()
                return e == ext && s.count == 3 && s.allSatisfy(\.isNumber)
            }
            .sorted()
        guard siblings.count >= 2, siblings.contains(url.lastPathComponent) else { return nil }
        return siblings.map { dir.appendingPathComponent($0).path }
    }

    /// 曲目标识归一化：分片组内任一分片 → 组首片路径；独立文件 → 自身。
    /// 用于"是否同一首曲"判断（分片前进不触发重分析）。
    public static func canonicalPath(_ path: String) -> String {
        shardGroup(path)?.first ?? path
    }

    /// 分片内字节偏移 → 组内全局偏移（前序分片字节总和 + 片内偏移）。
    /// 独立文件原样返回；无偏移 → nil。
    public static func globalOffsetBytes(path: String, offsetBytes: UInt64?) -> UInt64? {
        guard let offset = offsetBytes else { return nil }
        guard let group = shardGroup(path),
              let i = group.firstIndex(of: path) else { return offset }
        var base: UInt64 = 0
        for prev in group[..<i] {
            if let sz = fileSize(of: prev) { base += sz }
        }
        return base + offset
    }

    private static func fileSize(of path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?
            .first { $0.key == .size }?.value as? NSNumber)?.uint64Value
    }

    private static func mtimeOf(_ path: String) -> TimeInterval? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970
    }

    // MARK: - 分析

    /// 解码整曲算电平（分片组自动聚合）。格式不支持 / 读失败 / 无音频 → nil。
    public static func analyze(path: String) -> Result? {
        let files = shardGroup(path) ?? [path]
        let cacheKey = files.joined(separator: "\u{0}") as NSString
        // 组内任一片变化（如新分片落盘）都会使最大 mtime 变化 → 重分析
        guard let mtime = files.compactMap({ mtimeOf($0) }).max() else { return nil }
        if let hit = cache.object(forKey: cacheKey), hit.mtime == mtime {
            return hit.result
        }
        guard let result = analyzeFiles(files) else { return nil }
        cache.setObject(Box(mtime: mtime, result: result), forKey: cacheKey)
        return result
    }

    /// 顺序解码一组文件，统计量跨文件累计（分段表、峰值、RMS 均为整曲口径）。
    /// 单片失败跳过（容错缺片），全部失败 → nil。
    static func analyzeFiles(_ files: [String]) -> Result? {
        var peak: Double = 0
        var sumSq: Double = 0
        var sampleCount: Double = 0
        var segments: [Double] = []
        var segStart = 0.0
        var segEnergy = 0.0
        var segTarget: Double = 0
        var fileBytes: UInt64 = 0

        for path in files {
            guard let extFile = openClientFile(path) else { continue }
            defer { ExtAudioFileDispose(extFile.ref) }
            if segTarget == 0 {
                segTarget = extFile.sampleRate * 10 * Double(extFile.channels)
            }
            fileBytes += fileSize(of: path) ?? 0

            let framesPerRead: UInt32 = 65536
            let bytes = Int(framesPerRead) * 4 * extFile.channels
            var buffer = Data(count: bytes)
            while true {
                var got = framesPerRead
                var ok = false
                buffer.withUnsafeMutableBytes { raw in
                    var list = AudioBufferList(mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: UInt32(extFile.channels),
                                              mDataByteSize: UInt32(bytes),
                                              mData: raw.baseAddress))
                    ok = ExtAudioFileRead(extFile.ref, &got, &list) == noErr
                }
                guard ok, got > 0 else { break }
                let n = Int(got) * extFile.channels
                var blockSumSq = 0.0
                buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let samples = raw.bindMemory(to: Float.self).prefix(n)
                    for s in samples {
                        let v = Double(s)
                        let a = abs(v)
                        if a > peak { peak = a }
                        blockSumSq += v * v
                    }
                }
                sumSq += blockSumSq
                segEnergy += blockSumSq
                sampleCount += Double(n)
                if sampleCount - segStart >= segTarget {
                    segments.append(10 * log10(segEnergy / (sampleCount - segStart)))
                    segStart = sampleCount
                    segEnergy = 0
                }
            }
        }

        guard sampleCount > 0, peak > 0 else { return nil }
        // 尾段（≥1/3 段长才算数）
        let tailLen = sampleCount - segStart
        if tailLen >= segTarget / 3, segEnergy > 0 {
            segments.append(10 * log10(segEnergy / tailLen))
        }
        let rms = sqrt(sumSq / sampleCount)
        // duration = 样本数 /（声道数·采样率）= 样本数 /（segTarget/10）
        return Result(rmsDB: 20 * log10(rms), peakDB: 20 * log10(peak),
                      durationSec: sampleCount / segTarget * 10,
                      segmentSec: 10, segments: segments, fileSize: fileBytes)
    }

    /// 打开文件并设置 float32 交错 client format（保持原采样率/声道）。
    private static func openClientFile(_ path: String) -> (ref: ExtAudioFileRef,
                                                           sampleRate: Double,
                                                           channels: Int)? {
        let url = URL(fileURLWithPath: path)
        var extFile: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &extFile) == noErr, let file = extFile else {
            return nil
        }
        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: fileFormat))
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat,
                                      &size, &fileFormat) == noErr,
              fileFormat.mChannelsPerFrame > 0,
              fileFormat.mChannelsPerFrame <= 8 else { // 异常声道布局不碰
            ExtAudioFileDispose(file)
            return nil
        }
        var client = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * fileFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * fileFormat.mChannelsPerFrame,
            mChannelsPerFrame: fileFormat.mChannelsPerFrame,
            mBitsPerChannel: 32, mReserved: 0)
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr else {
            ExtAudioFileDispose(file)
            return nil
        }
        return (file, fileFormat.mSampleRate, Int(fileFormat.mChannelsPerFrame))
    }

    /// 由（全局）字节偏移估算播放位置，取所在分段的 RMS（「此刻声压」）。
    /// 压缩格式字节偏移 ≠ 时间（近似线性映射），10 秒分段粒度下误差可接受。
    public static func segmentRMS(_ result: Result, offsetBytes: UInt64?) -> Double? {
        guard !result.segments.isEmpty, result.durationSec > 0,
              let offset = offsetBytes, result.fileSize > 0 else { return nil }
        let frac = min(max(Double(offset) / Double(result.fileSize), 0), 1)
        let idx = min(Int(frac * result.durationSec / result.segmentSec),
                      result.segments.count - 1)
        return result.segments[idx]
    }
}
