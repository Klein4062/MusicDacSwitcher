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
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let samples = raw.bindMemory(to: Float.self).prefix(n)
                for s in samples {
                    let v = Double(s)
                    let a = abs(v)
                    if a > peak { peak = a }
                    sumSq += v * v
                }
            }
            sampleCount += Double(n)
        }

        guard sampleCount > 0, peak > 0 else { return nil }
        let rms = sqrt(sumSq / sampleCount)
        let result = Result(rmsDB: 20 * log10(rms), peakDB: 20 * log10(peak))
        cache.setObject(Box(mtime: mtime, result: result), forKey: path as NSString)
        return result
    }
}
