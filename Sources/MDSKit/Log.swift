// Log.swift — 日志输出：CLI 打印到 stdout，GUI 注册 handler 收集到界面

import Foundation

public enum LogSink {
    /// 注册后 log() 不再打印到 stdout，而是交给 handler（GUI 用）
    public static var handler: (@Sendable (String) -> Void)?
    private static let lock = NSLock()
}

public func log(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(df.string(from: Date()))] \(msg)"
    if let h = LogSink.handler {
        h(line)
    } else {
        print(line)
        fflush(stdout)
    }
}
