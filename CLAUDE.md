# CLAUDE.md

macOS 音频输出格式自动切换工具（菜单栏 App + CLI）。公共仓库（MIT）。

## 常用命令

```bash
swift build                          # 构建（无第三方依赖）
.build/debug/mds selftest            # 81 项自测，改逻辑后必须全绿
./scripts/make-app.sh --install      # 构建并安装 GUI 到 /Applications
pkill -f "MusicDacSwitcher.app/Contents/MacOS"; open /Applications/MusicDacSwitcher.app   # 重启 GUI
```

## 硬约束（改切换逻辑前必读 docs/coreaudio.md）

1. 写入硬件流的物理格式必须清除 `NonMixable(0x40)` 与非交错(`0x20`)标志——
   写入 `0x4c` 会让正在播放的数据错位（加速/断裂）。`FormatMatcher.preferMixable()`
   与 `FormatController.apply()` 两层防御不可移除。
2. 播放中写入是安全的（与「音频 MIDI 设置」同一条 HAL 属性），但写失败要登记
   pending 走空闲 ≥4s 重试，且同文件 30s 内不重试。
3. 切换正确性基准：结果与用户手动在「音频 MIDI 设置」里切换完全一致
   （物理 `0xc`、虚拟 float `0x9`）。

## 结构速览

- `Sources/MDSKit` 核心库：`FormatMatcher`（纯函数决策）、`FormatController`
  （写入执行）、`Watcher`（调度中枢）、`SourceProbe`（fd 扫描 + 文件头探测）、
  `DeviceWriteGuard`（稳定期/熔断，纯逻辑）、`HearingGuard`（听力保护声压估算，纯函数）、`TrackLevelAnalyzer`（曲目电平解码分析）、`HearingLog`（暴露历史与周剂量）
- `Sources/mds` CLI；`Sources/MDSBar` GUI（不用 `@State`，见 docs/development.md）
- 详细文档在 `docs/`：architecture（模块与参数表）、coreaudio（陷阱）、
  source-probe（探测与播放器矩阵）、development（构建与维护约定）

## 维护约定

- 时间参数（稳定期/熔断/空闲延迟等）改动 → 同步 docs/architecture.md 参数表
- 自测数量变化 → 同步 README 与本文件
- 提交信息用中文，说明动机与实测结果
