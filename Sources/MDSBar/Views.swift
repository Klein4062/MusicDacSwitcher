// Views.swift — 菜单栏面板界面（SwiftUI）

import SwiftUI
import MDSKit

// MARK: - 根视图

struct PopoverRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HeaderCard()
                AutoSwitchCard()
                FormatsCard()
                LogCard()
                FooterBar()
            }
            .padding(10)
        }
        .frame(minWidth: 380, minHeight: 640)
        .background(.ultraThinMaterial.opacity(0.001)) // 保持毛玻璃穿透
    }
}

// MARK: - 卡片容器

struct Card<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
    }
}

// MARK: - 顶部：设备 + 当前格式

struct HeaderCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.blue.opacity(0.30), .purple.opacity(0.14), .teal.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                // 设备选择 + 播放状态
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("跟随系统默认输出设备") { model.selectDevice(nil) }
                        Divider()
                        ForEach(model.deviceChoices, id: \.uid) { dev in
                            Button(dev.name) { model.selectDevice(dev.uid) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.deviceName).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    if let badge = model.listenModeBadge {
                        BadgeView(text: badge, fg: .secondary, bg: .primary.opacity(0.08))
                    }
                    Spacer()
                    RunningDot(running: model.isRunning)
                    if model.isHogged {
                        BadgeView(text: "HOG", fg: .orange, bg: .orange.opacity(0.15))
                    }
                }
                .font(.system(size: 12, weight: .medium))

                // 当前格式大字
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.currentRateLabel)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.3), value: model.currentRateLabel)
                    Text("kHz")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 6) {
                    BadgeView(text: "\(model.currentChannels) ch",
                              fg: .primary, bg: .primary.opacity(0.08))
                    BadgeView(text: "\(model.currentBits) bit \(model.currentIsFloat ? "Float" : "Int")",
                              fg: .white, bg: .accentColor)
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1))
    }
}

/// 播放中呼吸圆点（TimelineView 驱动，无需 @State）
struct RunningDot: View {
    var running: Bool

    var body: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let wave = 0.5 + 0.5 * sin(t * 2 * .pi / 1.8) // 1.8s 周期
                Circle()
                    .fill(running ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .scaleEffect(running ? 1.0 + 0.4 * wave : 1.0)
                    .shadow(color: running ? .green.opacity(0.9) : .clear,
                            radius: running ? 2 + 3 * wave : 0)
            }
            .frame(width: 10, height: 10)
            Text(running ? "播放中" : "空闲")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct BadgeView: View {
    var text: String
    var fg: Color
    var bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
    }
}

// MARK: - 自动切换

struct AutoSwitchCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("自动切换", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $model.autoSwitch)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                HStack {
                    Label("源探测", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11))
                    Text("读取正在播放的本地音频（FLAC/WAV/AIFF/DSD）并精确匹配格式")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Toggle("", isOn: $model.probeEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }

                Picker("位深", selection: $model.bitDepthMode) {
                    ForEach(AppModel.BitDepthMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.autoSwitch)

                HStack(alignment: .top) {
                    Text(model.autoSwitch
                         ? "播放时自动匹配音源采样率，并选择该采样率下设备支持的最佳格式"
                         : "已暂停 — 不会自动修改设备格式")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        model.optimizeNow()
                    } label: {
                        Label("立即优化", systemImage: "wand.and.stars")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.autoSwitch)
                }
            }
        }
    }
}

// MARK: - 格式矩阵

struct FormatsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("支持的格式", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("点按切换")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if model.rateRows.isEmpty {
                    Text("设备未报告能力")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(model.rateRows) { row in
                    RateRowView(row: row)
                }
            }
        }
    }
}

struct RateRowView: View {
    @EnvironmentObject var model: AppModel
    var row: AppModel.RateRow

    private var hovering: Bool { model.hoveredRate == row.rate && !row.isCurrent }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 11))
                .foregroundStyle(row.isCurrent ? Color.green : Color.secondary.opacity(0.5))

            Text(row.label)
                .font(.system(size: 12, weight: row.isCurrent ? .bold : .regular, design: .monospaced))
                .frame(width: 86, alignment: .leading)

            Spacer()

            HStack(spacing: 4) {
                ForEach(row.intBits, id: \.self) { bits in
                    bitChip(bits, float: false)
                }
                ForEach(row.floatBits, id: \.self) { bits in
                    bitChip(bits, float: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.apply(rate: row.rate) }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(Color.clear))
        )
        .onHover { model.setHovered($0 ? row.rate : nil) }
        .opacity(row.isCurrent ? 1.0 : 0.92)
    }

    @ViewBuilder
    private func bitChip(_ bits: Int, float: Bool) -> some View {
        let isCurrent = row.isCurrent && row.currentBits == bits
        Text("\(bits)\(float ? "f" : "")")
            .font(.system(size: 10, weight: isCurrent ? .bold : .medium, design: .monospaced))
            .foregroundStyle(isCurrent ? Color.white : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
    }
}

// MARK: - 日志

struct LogCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("活动日志", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("清空") { model.logs.removeAll() }
                        .controlSize(.mini)
                        .buttonStyle(.borderless)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logs.suffix(80).reversed().enumerated()),
                                id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(height: 96)
            }
        }
    }
}

// MARK: - 底部

struct FooterBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Toggle(isOn: $model.launchAtLogin) {
                Label("登录时启动", systemImage: "arrow.clockwise.circle")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("退出 MusicDacSwitcher")
        }
        .padding(.horizontal, 4)
    }
}
