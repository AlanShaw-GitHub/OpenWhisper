import SwiftUI
import ServiceManagement

struct MenuContentView: View {
    @Bindable var state: AppState
    @AppStorage("settings.tab") private var tabName = SettingsTab.general.rawValue
    @State private var loginError: String?
    private var provider: Provider { state.configuration.provider }
    private var tab: Binding<SettingsTab> {
        Binding(get: { SettingsTab(rawValue: tabName) ?? .general }, set: { tabName = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SettingsTabBar(selection: tab).padding(.horizontal, 14).padding(.bottom, 10)
            ScrollView(.vertical) {
                GlassGroup(spacing: 12) {
                    VStack(spacing: 12) {
                        if !state.permissions.microphone || !state.permissions.accessibility { permissionsCard }
                        switch tab.wrappedValue {
                        case .general: outputCard; recognitionCard; audioCard; postProcessingCard; appCard
                        case .service: serviceCard
                        case .history: historyCard
                        case .keys: keysCard; permissionsStatusCard; quitCard
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .modifier(NoScrollEdgeEffect())
            .frame(maxHeight: Self.cardsMaxHeight)
            if state.phase.active { recordingFooter }
        }
        .font(.system(size: 13))
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        // Strings are looked up when views are built, so a language switch rebuilds the whole panel.
        .id(state.configuration.interfaceLanguage)
        .environment(\.locale, Localization.shared.locale)
        .onAppear {
            state.permissions.refresh(); state.refreshKeys(); state.refreshInputDevices(); state.prepareMicrophone()
        }
    }
    /// Leave room for the menu bar, the popover arrow and the header on short laptop screens.
    static var cardsMaxHeight: CGFloat {
        #if OPENWHISPER_DIAGNOSTICS
        if let value = ProcessInfo.processInfo.environment["OPENWHISPER_UI_MAX_HEIGHT"], let height = Double(value) { return height }
        #endif
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(360, screen - 230)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.33, green: 0.56, blue: 1.0), Color(red: 0.62, green: 0.38, blue: 0.98)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }.frame(width: 42, height: 42).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "OpenWhisper").font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(state.phase.active ? state.phase.title : L("按 %@ 开始听写", state.configuration.shortcut.display))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusCapsule(phase: state.phase)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    private var recordingFooter: some View {
        HStack {
            Button(L("取消")) { state.cancel() }.glassButton()
            Spacer()
            Button(state.canStopRecording ? L("停止并转写") : state.phase.title) { state.stopFromMenu() }
                .glassButton(prominent: true).disabled(!state.canStopRecording)
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    // MARK: Service tab

    private var serviceCard: some View {
        SettingsCard {
            SettingsRow(icon: "sparkles", title: L("转写服务"), subtitle: provider.modelName)
            Picker(L("转写服务"), selection: $state.configuration.provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().rowIndent()
            if !state.hasKey(provider) {
                Text(L("尚未填写 %@ 的 API key，请到「密钥」页填写。", provider.title)).font(.system(size: 11)).foregroundStyle(.orange).rowIndent()
            }
            switch provider {
            case .elevenlabs:
                RowDivider()
                SettingsRow(icon: "text.badge.minus", title: L("去除语气词、口误与重复起句"), subtitle: "ElevenLabs no_verbatim") {
                    Toggle(L("去除语气词"), isOn: $state.configuration.elevenLabsSettings.noVerbatim).switchToggle()
                }
            case .openai:
                RowDivider()
                SettingsRow(icon: "gauge.with.dots.needle.33percent", title: L("实时延迟"), subtitle: L("越低越快，越高越准；仅流式输出")) {
                    Picker(L("实时延迟"), selection: $state.configuration.openAILiveDelay) {
                        ForEach(OpenAIRealtimeOption.delays, id: \.value) { Text($0.title).tag($0.value) }
                    }.labelsHidden().frame(width: 128).disabled(state.configuration.mode != .streaming)
                }
                RowDivider()
                SettingsRow(icon: "text.quote", title: L("上下文提示"), subtitle: L("描述录音场景、人名或术语，两种模式都会发送"))
                TextField(L("例如：产品评审会议，提到 Acme 和 eSIM"), text: $state.configuration.openAIPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3).font(.system(size: 12)).rowIndent()
                    .accessibilityLabel(L("上下文提示"))
                RowDivider()
                modelField(L("完整录音模型"), value: $state.configuration.openAIBatchModel)
                modelField(L("实时模型"), value: $state.configuration.openAILiveModel)
            case .muse:
                RowDivider()
                modelField(L("转写模型"), value: $state.configuration.museModel)
            }
        }.disabled(state.phase.active)
    }

    private func modelField(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            TextField(title, text: value).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 190)
                .accessibilityLabel(title)
        }.rowIndent()
    }

    // MARK: General tab

    private var outputCard: some View {
        SettingsCard {
            SettingsRow(icon: "text.cursor", title: L("输出方式"), subtitle: state.configuration.mode.detail)
            Picker(L("输出方式"), selection: $state.configuration.mode) {
                ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().rowIndent()
            if state.configuration.mode == .streaming {
                SettingsSubRow(icon: "text.append", title: L("边说边写进输入框（实验）"),
                               subtitle: L("只追加新文字，从不回改；识别有修正或智能整理改过时，完整文字复制到剪贴板")) {
                    Toggle(L("边说边写进输入框（实验）"), isOn: $state.configuration.liveInsertion).switchToggle()
                }
            }
            RowDivider()
            SettingsRow(icon: "command", title: L("录音快捷键"), subtitle: L("按一次开始，再按一次结束")) {
                ShortcutRecorder(shortcut: state.configuration.shortcut,
                    onStart: { state.shortcutService.suspend() },
                    onChange: { state.setShortcut($0) }, onEnd: { state.registerShortcut(clearError: false) })
                    .frame(width: 128, height: 28)
            }
            if let error = state.shortcutError { Text(error).font(.system(size: 11)).foregroundStyle(.red).rowIndent() }
        }.disabled(state.phase.active)
    }

    private var recognitionCard: some View {
        SettingsCard { SpeechBiasView(state: state) }.disabled(state.phase.active)
    }

    private var audioCard: some View {
        SettingsCard {
            SettingsRow(icon: "mic", title: L("语音输入源"), subtitle: L("跟随 macOS 或手动指定")) {
                Picker(L("语音输入源"), selection: $state.configuration.inputDeviceUID) {
                    Text(L("系统默认")).tag("")
                    ForEach(state.inputDevices) { Text($0.name).tag($0.uid) }
                    if !state.configuration.inputDeviceUID.isEmpty, !state.inputDevices.contains(where: { $0.uid == state.configuration.inputDeviceUID }) {
                        Text(L("已保存的设备（未连接）")).tag(state.configuration.inputDeviceUID)
                    }
                }.labelsHidden().frame(width: 170).accessibilityLabel(L("语音输入源"))
                    .onChange(of: state.configuration.inputDeviceUID) { _, _ in state.prepareMicrophone() }
            }
            Text(L("说话声偏小时会自动提升音量，不需要额外设置。")).hint().rowIndent()
            RowDivider()
            SettingsRow(icon: "waveform.badge.minus", title: L("系统语音处理"), subtitle: L("macOS 自带的降噪、回声消除与增益控制，先于任何服务处理声音")) {
                Toggle(L("系统语音处理"), isOn: $state.configuration.systemVoiceProcessing).switchToggle()
                    .onChange(of: state.configuration.systemVoiceProcessing) { _, _ in state.prepareMicrophone() }
            }
        }.disabled(state.phase.active)
    }

    private var postProcessingCard: some View {
        SettingsCard { PostProcessingView(state: state) }.disabled(state.phase.active)
    }

    private var appCard: some View {
        SettingsCard {
            SettingsRow(icon: "character.bubble", title: L("界面语言")) {
                Picker(L("界面语言"), selection: $state.configuration.interfaceLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language == .system ? L("跟随系统（%@）", AppLanguage.matching(Locale.preferredLanguages).nativeName) : language.nativeName)
                            .tag(language)
                    }
                }.labelsHidden().frame(width: 170).accessibilityLabel(L("界面语言"))
            }
            RowDivider()
            SettingsRow(icon: "power", title: L("登录时启动")) {
                Toggle(L("登录时启动"), isOn: Binding(get: { state.launchAtLogin }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        state.launchAtLogin = SMAppService.mainApp.status == .enabled
                    } catch { loginError = error.localizedDescription }
                })).switchToggle()
            }
            if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(.red).rowIndent() }
        }
    }

    // MARK: History tab

    private var historyCard: some View {
        SettingsCard {
            SettingsRow(icon: "clock.arrow.circlepath", title: L("最近转写"), subtitle: L("最多保留 5 条，只存在内存里，退出后清除"))
            if state.history.isEmpty {
                Text(L("还没有转写记录。")).font(.system(size: 12)).foregroundStyle(.secondary).rowIndent()
            }
            ForEach(Array(state.history.enumerated()), id: \.offset) { index, text in
                if index > 0 { RowDivider() }
                HStack(alignment: .top, spacing: 8) {
                    Text(text).font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("复制")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    }.glassButton().controlSize(.small)
                }.rowIndent()
            }
        }
    }

    // MARK: Keys tab

    private var keysCard: some View {
        SettingsCard {
            SettingsRow(icon: "waveform", title: L("语音服务"), subtitle: L("填写你要使用的服务即可"))
            ForEach(Provider.allCases) { provider in
                CredentialEditor(state: state, keyID: provider.rawValue, title: L("%@ API key", provider.title))
            }
            RowDivider()
            SettingsRow(icon: "wand.and.stars", title: L("智能整理文本模型"), subtitle: L("OpenAI 与语音服务共用同一个 key"))
            ForEach([PostProcessingEngine.deepseek, .gemini]) { engine in
                CredentialEditor(state: state, keyID: engine.keyID, title: engine.keyTitle)
            }
        }
    }

    private var permissionsStatusCard: some View {
        SettingsCard {
            SettingsRow(icon: "checkmark.shield.fill", title: L("系统权限")) {
                Button(L("重新检查")) { state.permissions.refresh() }.glassButton().controlSize(.small)
            }
            permissionRows
        }
    }

    private var quitCard: some View {
        HStack {
            Spacer()
            Button(L("退出 OpenWhisper")) { NSApplication.shared.terminate(nil) }.glassButton().controlSize(.small)
        }
    }

    // MARK: Shared pieces

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(icon: "hand.raised.fill", title: L("首次使用需要两个权限"), subtitle: L("之后不再提示"))
            permissionRows
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassSurface(radius: 18, tint: .orange))
    }
    @ViewBuilder private var permissionRows: some View {
        permissionRow(icon: "mic.fill", title: L("麦克风"), detail: L("录制你的声音"), granted: state.permissions.microphone) {
            Task { await state.permissions.requestMicrophone(); state.prepareMicrophone() }
        }
        permissionRow(icon: "accessibility", title: L("辅助功能"), detail: L("把文字写进当前文本框"), granted: state.permissions.accessibility) {
            state.permissions.requestAccessibility()
        }
    }
    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsSubRow(icon: icon, title: title, subtitle: detail) {
            if granted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button(L("允许"), action: action).glassButton(prominent: true).controlSize(.small) }
        }
    }
}

/// The scroll view sits on the same popover material as the header; the default edge effect painted a
/// visibly different band at its top and bottom.
private struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.scrollEdgeEffectStyle(.none, for: .all) } else { content }
    }
}
