import SwiftUI

/// Grouped, inset card in the spirit of iOS Settings: Liquid Glass on macOS 26+, system material below.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassSurface(radius: 18))
    }
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color? = nil
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.18), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.06)))
        }
    }
}

/// Neighbouring glass surfaces must share one container so their refraction stays consistent.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Quiet monochrome glyph tiles: the symbol carries the meaning, the tile only aligns the rows.
struct IconTile: View {
    let systemName: String
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: systemName).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.primary.opacity(0.88))
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon; self.title = title; self.subtitle = subtitle; self.trailing = trailing
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
extension SettingsRow where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Second-level entry under a group row: indented to the group's text, smaller glyph, always expanded.
struct SettingsSubRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon; self.title = title; self.subtitle = subtitle; self.trailing = trailing
    }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(systemName: icon, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }.rowIndent()
    }
}
extension SettingsSubRow where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil) { self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() } }
}
struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 42) }
}

/// Content that belongs to the row above it (fields, pickers, hints) lines up with the row's text.
struct RowIndent: ViewModifier {
    func body(content: Content) -> some View { content.padding(.leading, 42) }
}
extension View {
    func rowIndent() -> some View { modifier(RowIndent()) }
    func hint() -> some View { font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
    func switchToggle() -> some View { toggleStyle(.switch).labelsHidden().controlSize(.small) }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, service, history, keys
    var id: String { rawValue }
    var title: String {
        switch self { case .general: return L("通用"); case .service: return L("服务"); case .history: return L("历史"); case .keys: return L("密钥") }
    }
    var icon: String {
        switch self { case .general: return "slider.horizontal.3"; case .service: return "waveform"; case .history: return "clock.arrow.circlepath"; case .keys: return "key.fill" }
    }
}

/// Top tab strip in the style of a utility's preferences: icon over label, the selection on its own glass pill.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 17, weight: .medium))
                        Text(tab.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.12))
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title).accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .modifier(GlassSurface(radius: 16))
    }
}

struct StatusCapsule: View {
    let phase: AppPhase
    private var color: Color {
        switch phase {
        case .idle, .success: return .green
        case .recording: return .red
        case .connecting, .processing: return .orange
        case .failed: return .red
        }
    }
    private var label: String {
        switch phase {
        case .idle: return L("就绪")
        case .connecting: return L("连接中")
        case .recording: return L("录音中")
        case .processing: return L("转写中")
        case .success: return L("已完成")
        case .failed: return L("出错")
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .modifier(GlassSurface(radius: 20))
        .accessibilityLabel(L("状态：%@", label))
    }
}
