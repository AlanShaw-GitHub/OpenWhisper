import SwiftUI

struct CredentialEditor: View {
    let state: AppState
    let keyID: String
    let title: String
    @State private var draft = ""
    @State private var editing = false
    @State private var error: String?
    init(state: AppState, keyID: String, title: String) { self.state = state; self.keyID = keyID; self.title = title }
    private var saved: Bool { state.keyPresent[keyID] == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSubRow(icon: "key.fill", title: title, subtitle: saved ? L("已保存在本机") : L("尚未填写")) {
                Button(editing ? L("收起") : (saved ? L("修改") : L("填写"))) { editing.toggle(); draft = ""; error = nil }
                    .glassButton(prominent: !saved && !editing).controlSize(.small)
            }
            if editing {
                HStack(spacing: 8) {
                    SecureField(L("粘贴你的 API key"), text: $draft).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(title)
                    Button(L("保存")) {
                        do { try state.saveKey(draft, id: keyID); draft = ""; editing = false; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.glassButton(prominent: true).controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.rowIndent()
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).rowIndent() }
        }
    }
}
