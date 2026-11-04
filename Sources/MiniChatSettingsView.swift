import SwiftUI
import AppKit

// Mini's AI Chat settings do not alter Coding Agent configuration.
struct MiniChatSettingsView: View {
    let onSaved: () -> Void
    @Environment(\.presentationMode) private var presentationMode
    @State private var selection = "deepseek-flash"
    @State private var customModel = ""
    @State private var thinking = false
    @State private var reuseAgentKey = false
    @State private var newKey = ""
    @State private var keyExists = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mini 酱 · DeepSeek AI Chat").font(.system(size: 20, weight: .bold))
                    Text("独立闲聊，不操作文件或项目，不影响编程 Agent。").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Button("关闭") { presentationMode.wrappedValue.dismiss() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Mini 酱专用模型").font(.system(size: 13, weight: .semibold))
                Picker("模型", selection: $selection) {
                    Text("Flash · 日常聊天").tag("deepseek-flash")
                    Text("V4 Pro · 高级聊天").tag("deepseek-v4-pro")
                    Text("自定义模型 ID").tag("custom")
                }
                .pickerStyle(.segmented)
                if selection == "custom" {
                    TextField("DeepSeek API 返回的模型 ID", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                }
                Text("使用 DeepSeek 官方 https://api.deepseek.com，聊天也会消耗你的 API 余额。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Toggle("启用思考模式（可能增加 Token 消耗）", isOn: $thinking)
                .font(.system(size: 12))
            Divider()
            Toggle("复用编程 Agent 的 DeepSeek API Key", isOn: $reuseAgentKey)
                .font(.system(size: 12))
            if reuseAgentKey {
                Text("只复用钥匙串中的密钥；不会读取编程项目和任务对话。需要编程 Agent 的地址为 api.deepseek.com。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mini 酱独立 API Key").font(.system(size: 13, weight: .semibold))
                    SecureField(keyExists ? "已保存在 Mac 钥匙串；留空则不修改" : "粘贴 DeepSeek API Key", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                    Text("密钥只存 Mac 钥匙串，不保存到工程、不上传 GitHub。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("保存 Mini 酱聊天设置") { saveSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(21)
        .frame(width: 490)
        .onAppear {
            let setting = MiniChatConfig.load()
            selection = setting.modelChoice
            customModel = setting.customModel
            thinking = setting.thinking
            reuseAgentKey = setting.reuseAgentKey
            keyExists = MiniChatKeychain.load() != nil
        }
    }

    private func saveSettings() {
        do {
            let cfg = MiniChatConfig(modelChoice: selection,
                                     customModel: customModel,
                                     thinking: thinking,
                                     reuseAgentKey: reuseAgentKey)
            guard !cfg.modelID.isEmpty && cfg.modelID.count < 100 else {
                throw MiniError("请填写有效的模型 ID")
            }
            if !reuseAgentKey && !newKey.isEmpty {
                try MiniChatKeychain.save(newKey.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard cfg.hasKey || (!reuseAgentKey && !newKey.isEmpty) else {
                throw MiniError("请填写独立 API Key，或设置可复用的编程 Agent DeepSeek Key")
            }
            cfg.save()
            onSaved()
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
