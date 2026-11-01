import SwiftUI

struct PostProcessingView: View {
    @Bindable var state: AppState
    private var settings: PostProcessingSettings { state.configuration.postProcessing }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(icon: "wand.and.stars", title: L("智能整理"),
                        subtitle: L("停止后用 %@ 整理全文：纠正听错的词、语气词、标点、数字、列表", settings.model)) {
                Toggle(L("智能整理"), isOn: $state.configuration.postProcessing.enabled).switchToggle()
            }
            if settings.enabled {
                HStack {
                    Text(L("文本模型")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Picker(L("文本模型"), selection: $state.configuration.postProcessing.engine) {
                        ForEach(PostProcessingEngine.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190).accessibilityLabel(L("智能整理文本模型"))
                }.rowIndent()
                if settings.engine.allowsCustomModel {
                    HStack {
                        Text(L("模型名")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        TextField(settings.engine.defaultModel, text: settings.engine == .openai ? $state.configuration.postProcessing.openAIModel : $state.configuration.postProcessing.geminiModel)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 190)
                            .accessibilityLabel(L("%@ 模型名", settings.engine.title))
                    }.rowIndent()
                }
                if state.keyPresent[settings.engine.keyID] != true {
                    Text(L("尚未填写 %@，请到「密钥」页填写；没有 key 时保留原文。", settings.engine.keyTitle))
                        .font(.system(size: 11)).foregroundStyle(.orange).rowIndent()
                }
                HStack {
                    Text(L("规则")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(PostProcessingRule.allCases) { rule in
                            Toggle(rule.title, isOn: Binding(get: { settings.rules.contains(rule.rawValue) }, set: { selected in
                                var rules = settings.rules
                                rules.removeAll { $0 == rule.rawValue }
                                if selected { rules.append(rule.rawValue) }
                                state.configuration.postProcessing.rules = rules
                            }))
                        }
                    } label: { Text(L("已选 %d 项", settings.selectedRules.count)).font(.system(size: 12)) }
                    .frame(width: 150).accessibilityLabel(L("智能整理规则，可多选"))
                }.rowIndent()
                TextField(L("自定义整理指令（可选）"), text: $state.configuration.postProcessing.customInstruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3).font(.system(size: 12)).rowIndent()
                    .accessibilityLabel(L("自定义整理指令"))
                Text(hint).hint().rowIndent()
            }
        }
    }
    private var hint: String {
        switch settings.engine {
        case .deepseek: return L("DeepSeek Flash 关闭思考模式，约 1 秒；按文本 token 计费，一段听写约几百 token；失败时保留原文。")
        case .openai: return L("OpenAI 默认 gpt-6-luna，约 1–2 秒；与语音服务共用 OpenAI key；失败时保留原文。")
        case .gemini: return L("Gemini 默认 gemini-3.5-flash-lite，走 OpenAI 兼容接口；需要单独的 Gemini key；失败时保留原文。")
        }
    }
}
