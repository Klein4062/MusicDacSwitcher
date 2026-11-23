# 开发说明

## 构建与测试

```bash
swift build                    # 调试构建（.build/debug/mds）
swift build -c release         # 发布构建（.build/release/mds）
.build/debug/mds selftest      # 83 项内置自测，改任何决策逻辑后必须全绿
./scripts/make-app.sh --install  # 构建 GUI 并安装到 /Applications
```

- 无第三方依赖；要求 macOS 12+ 与 Xcode Command Line Tools。
- 自测覆盖：匹配算法、格式标志清洗、文件头解析（含 `.uc!`）、播放识别
  （offset 前进 / 写句柄过滤）、稳定期与掉线熔断时间线、听力保护声压估算（峰值/平均双口径）。
- **纯函数层优先**：`FormatMatcher` / `DeviceWriteGuard` / `SourceProbe` 的解析
  都是纯逻辑，新行为先写成可自测的纯函数，再由 `Watcher` / `FormatController` 接线。

## GUI 的无 Xcode 约束

GUI（`Sources/MDSBar`）为纯 Swift Package 构建，不用 Xcode 项目。CLT 环境下
SwiftUI 宏插件缺失，因此：

- **不使用 `@State`**（会引入宏依赖）：悬停等状态集中在 `AppModel`，
  动画用 `TimelineView` 驱动
- 本机若装有完整 Xcode 则一切照常，无需改配置

## 常用排查

```bash
mds list / mds format          # 设备能力矩阵 / 当前格式
mds probe                      # 源探测视角（谁在播、offset 是否前进）
mds playtest <文件>            # 端到端验证：真实 IO + 文件读取的静音播放
log show --predicate 'process == "coreaudiod"' --info --debug
                               # HAL 内部行为（PauseIO/ResumeIO、驱动调用）
```

真机复测格式稳定性时，注意区分物理/虚拟格式（虚拟应为 float `0x9`），
并观察写入后 ≥5s 是否回滚。

## 文档维护约定

- 时间参数改动 → 同步 `docs/architecture.md` 的参数表
- 切换逻辑改动 → 先读 `docs/coreaudio.md`（NonMixable 陷阱两层防御不可移除）
- 自测数量变化 → 同步 README 与 CLAUDE.md 中的数字
