// TrackLevel.swift — 曲目电平分析：解码音频文件算平均 RMS / 峰值（dBFS）
//
// 用途：听力保护估算的「平均口径」需要曲目实际电平——满幅假设
// （0 dBFS）比真实音乐平均 RMS 高 10~20 dB（古典 −22 左右、响度战争
// 流行 −8 左右），录音电平差异是估算最大的系统性偏差。源探测已经
// 知道正在播放哪个文件，这里按 path 解码实测。
//
// 限制：DSF/DSD 与加密缓存（.uc!、.mflac）CoreAudio 解不了 → 返回
// nil，调用方回退静态峰值因子参数。分析在后台线程调用；结果按
// path + 修改时间缓存（同一文件不重复解码）。

import Foundation
import AudioToolbox

public enum TrackLevelAnalyzer {

    public struct Result: Equatable {
        /// 全文件平均 RMS（dBFS，≤ 0）
        public let rmsDB: Double
        /// 全文件真峰值近似（dBFS，≤ 0）
        public let peakDB: Double
        /// 总时长（秒）
        public let durationSec: Double
        /// 分段长度（秒，固定 10）
        public let segmentSec: Double
        /// 按播放顺序的分段 RMS（dBFS），供「此刻声压」按位置取用
        public let segments: [Double]
        /// 文件字节数（配合 fd 读取偏移估算播放位置）
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

    /// 解码整个文件算电平。格式不支持 / 读失败 / 无音频 → nil。
    public static func analyze(path: String) -> Result? {
        let url = URL(fileURLWithPath: path)
        guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970 else { return nil }

        if let hit = cache.object(forKey: path as NSString), hit.mtime == mtime {
            return hit.result
        }

        var extFile: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &extFile) == noErr, let file = extFile else {
            return nil
        }
        defer { ExtAudioFileDispose(file) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: fileFormat))
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat,
                                      &size, &fileFormat) == noErr,
              fileFormat.mChannelsPerFrame > 0 else { return nil }
        guard fileFormat.mChannelsPerFrame <= 8 else { return nil } // 异常声道布局不碰

        // 客户端格式：float32 交错，保持原采样率与声道数
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
            return nil
        }

        let framesPerRead: UInt32 = 65536
        let bytes = Int(framesPerRead) * Int(client.mBytesPerFrame)
        var buffer = Data(count: bytes)
        var peak: Double = 0
        var sumSq: Double = 0
        var sampleCount: Double = 0
        // 分段累计（每 10s 一段，块粒度切分，边界误差 ≤1.4s 可忽略）
        var segments: [Double] = []
        var segStart = 0.0
        var segEnergy = 0.0
        let segTarget = fileFormat.mSampleRate * 10 * Double(fileFormat.mChannelsPerFrame)

        while true {
            var got = framesPerRead
            var ok = false
            buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: client.mChannelsPerFrame,
                                          mDataByteSize: UInt32(bytes),
                                          mData: raw.baseAddress))
                ok = ExtAudioFileRead(file, &got, &list) == noErr
            }
            guard ok, got > 0 else { break }
            let n = Int(got) * Int(client.mChannelsPerFrame)
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

        guard sampleCount > 0, peak > 0 else { return nil }
        // 尾段（≥1/3 段长才算数）
        let tailLen = sampleCount - segStart
        if tailLen >= segTarget / 3, segEnergy > 0 {
            segments.append(10 * log10(segEnergy / tailLen))
        }
        let rms = sqrt(sumSq / sampleCount)
        let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: path))?
            .first { $0.key == .size }?.value as? NSNumber)?.uint64Value ?? 0
        let result = Result(rmsDB: 20 * log10(rms), peakDB: 20 * log10(peak),
                            durationSec: sampleCount / Double(fileFormat.mChannelsPerFrame)
                                / fileFormat.mSampleRate,
                            segmentSec: 10, segments: segments, fileSize: fileBytes)
        cache.setObject(Box(mtime: mtime, result: result), forKey: path as NSString)
        return result
    }

    /// 由 fd 读取偏移（字节）估算播放位置，取所在分段的 RMS（「此刻声压」）。
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
