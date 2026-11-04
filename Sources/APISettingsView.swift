import SwiftUI
import AppKit

struct APISettingsView: View {
    @Binding var isOpen: Bool
    @State private var url = ""
    @State private var model = ""
    @State private var manualModelChoice = "custom"
    @State private var key = ""
    @State private var runCommands = false
    @State private var tokenBudget = 0
    @State private var autoRouting = true
    @State private var fastModel = ""
    @State private var strongModel = ""
    @State private var errorText = ""
    @State private var keyExists = false
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("连接自己的 AI API").font(.system(size: 20, weight: .bold))
                Spacer()
                Button("关闭") { isOpen = false }
            }
            Text("首次设置一次即可。需要 OpenAI Chat Completions 兼容 API，模型必须支持工具调用。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            // macOS 12's ViewBuilder supports at most ten direct children.
            // Group these fields so the outer VStack stays under that limit.
            Group {
                fieldGroup("API 地址（Base URL）") {
                    TextField("https://api.deepseek.com", text: $url).textFieldStyle(.roundedBorder)
                }
                fieldGroup("编程 Agent 模型选择") {
                    Picker("运行模式", selection: $autoRouting) {
                        Text("自动智能分配").tag(true)
                        Text("自己选择模型").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !autoRouting {
                        Picker("使用模型", selection: $manualModelChoice) {
                            Text("DeepSeek Flash · 轻量快速").tag("deepseek-flash")
                            Text("DeepSeek V4 Pro · 复杂任务").tag("deepseek-v4-pro")
                            Text("自定义模型 ID · 其他兼容 API").tag("custom")
                        }
                        .pickerStyle(.menu)
                        if manualModelChoice == "custom" {
                            TextField("输入完整模型 ID（来自 API 提供商）", text: $model)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("手动模式固定使用所选模型，不再被自动路由更换。")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    } else {
                        TextField("默认模型 ID（自动调度不适用时的备用模型）", text: $model)
                            .textFieldStyle(.roundedBorder)
                        Text("自动模式：Flash 执行任务，复杂问题按需切换 Pro；不适用自动调度时使用上面的模型 ID。")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                fieldGroup("API Key") {
                    SecureField(keyExists ? "已保存在钥匙串；留空则不改变" : "输入自己的 API Key", text: $key)
                        .textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("自动模型调度配置（仅在自动模式使用）")
                    .font(.system(size: 12, weight: .semibold))
                if autoRouting {
                    HStack(spacing: 10) {
                        TextField("快速模型：deepseek-flash", text: $fastModel).textFieldStyle(.roundedBorder)
                        TextField("复杂模型：deepseek-v4-pro", text: $strongModel).textFieldStyle(.roundedBorder)
                    }
                    Text("DeepSeek 官方地址留空即自动填入默认值；其他 API 必须填写两个准确的模型 ID 才会自动切换。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            HStack {
                Text("可选 Token 预算（默认不限）")
                Spacer()
                Picker("", selection: $tokenBudget) {
                    Text("不限（默认）").tag(0)
                    Text("3 万（可选）").tag(30_000)
                    Text("12 万（可选）").tag(120_000)
                    Text("30 万（可选）").tag(300_000)
                }.frame(width: 175)
            }.font(.system(size: 12))
            Text("只有真实测试通过才能交付。关闭下方的本地运行权限时，Agent 会保存任务并停止付费 API 请求。重复无进展也会停止无效调用。")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Toggle("允许 Mini 自动运行项目测试和编译命令", isOn: $runCommands)
                .font(.system(size: 12))
            Text("开启后，AI 生成的程序会在你的 Mac 上真实执行。仅建议在你信任的项目中使用；目前不是系统级沙箱。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if !errorText.isEmpty { Text(errorText).font(.caption).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("保存并开始") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(23)
        .frame(width: 510)
        .onAppear {
            let settings = AppConfig.load()
            url = settings.baseURL; model = settings.model.isEmpty ? "deepseek-flash" : settings.model
            runCommands = settings.autoRun; tokenBudget = settings.tokenBudget
            autoRouting = settings.autoRouting; fastModel = settings.fastModel; strongModel = settings.strongModel
            manualModelChoice = ["deepseek-flash", "deepseek-v4-pro"].contains(settings.model)
                ? settings.model : "custom"
            keyExists = APIKeychain.load() != nil
        }
    }
    private func fieldGroup<Child: View>(_ title: String, @ViewBuilder child: () -> Child) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            child()
        }
    }
    private func save() {
        do {
            let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try AIService.endpoint(from: clean)
            let chosenModel = (autoRouting || manualModelChoice == "custom")
                ? model.trimmingCharacters(in: .whitespacesAndNewlines)
                : manualModelChoice
            guard !chosenModel.isEmpty else { throw MiniError("请选择模型，或填写完整的自定义模型 ID") }
            if key.isEmpty && !keyExists { throw MiniError("请填写 API Key") }
            if !key.isEmpty { try APIKeychain.save(key) }
            AppConfig(baseURL: clean, model: chosenModel, autoRun: runCommands, tokenBudget: tokenBudget,
                      autoRouting: autoRouting, fastModel: fastModel, strongModel: strongModel).save()
            isOpen = false
        } catch { errorText = error.localizedDescription }
    }
}
