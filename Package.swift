// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicDacSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        // 核心逻辑库：CoreAudio 封装 + 匹配算法 + 切换执行 + 监听
        .target(name: "MDSKit", path: "Sources/MDSKit"),
        // 命令行工具
        .executableTarget(name: "mds", dependencies: ["MDSKit"], path: "Sources/mds"),
        // 菜单栏图形界面
        .executableTarget(name: "MDSBar", dependencies: ["MDSKit"], path: "Sources/MDSBar"),
    ]
)
