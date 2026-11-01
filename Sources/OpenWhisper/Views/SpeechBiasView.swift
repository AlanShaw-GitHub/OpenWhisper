import SwiftUI

struct SpeechBiasView: View {
    @Bindable var state: AppState
    private var selected: [String] { state.configuration.languageCodes }
    private var summary: String {
        if selected.isEmpty { return L("自动识别") }
        if selected.count > 2 { return L("已选 %d 种语言", selected.count) }
        return SpeechLanguage.names(for: selected, provider: state.configuration.provider)
            .map { $0.components(separatedBy: " · ")[0] }.joined(separator: L("、"))
    }
    private var keywordHint: String {
        if state.configuration.provider == .elevenlabs {
            return state.configuration.mode == .streaming ? L("逗号分隔，每项最多 20 字符") : L("逗号分隔；多种语言时自动识别")
        }
        return L("逗号分隔，专有名词可包含空格")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(icon: "globe", title: L("识别语言"), subtitle: L("可多选，留空自动识别")) {
                Menu {
                    Toggle(L("自动识别"), isOn: Binding(get: { selected.isEmpty }, set: { enabled in
                        if enabled { state.configuration.languageCodes = [] }
                    }))
                    Divider()
                    ForEach(SpeechLanguage.available(for: state.configuration.provider)) { language in
                        Toggle(language.title, isOn: Binding(get: { selected.contains(language.code) }, set: { enabled in
                            var codes = selected
                            if enabled { if !codes.contains(language.code) { codes.append(language.code) } }
                            else { codes.removeAll { $0 == language.code } }
                            state.configuration.languageCodes = codes
                        }))
                    }
                } label: { Text(summary).font(.system(size: 12)).lineLimit(1) }
                .frame(width: 150).accessibilityLabel(L("识别语言，可多选"))
            }
            RowDivider()
            SettingsRow(icon: "text.book.closed.fill", title: L("自定义词汇"), subtitle: keywordHint) {
                Text(L("%d 个", state.configuration.speechSettings.keywords.count)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField(L("例如 Acme Mobile, eSIM, 5G"), text: $state.configuration.speechSettings.keywordText)
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).rowIndent()
                .accessibilityLabel(L("%@ 自定义词汇", state.configuration.provider.title))
            if state.configuration.provider == .elevenlabs && !state.configuration.speechSettings.keywords.isEmpty {
                Text(L("自定义词汇附加服务费 20%。")).hint().rowIndent()
            }
        }
    }
}
