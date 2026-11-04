import Foundation
import SwiftUI
import AppKit
import Security

// Mini Chat is deliberately isolated from the coding Agent. No tool definitions,
// project files, coding messages, or coding-agent instructions enter these requests.
struct MiniCompanionLine: Identifiable, Codable {
    enum Who: String, Codable { case user, mini }
    let id: UUID
    let who: Who
    let content: String
    init(_ who: Who, _ content: String) { id = UUID(); self.who = who; self.content = content }
}

struct MiniChatConfig {
    var modelChoice: String
    var customModel: String
    var thinking: Bool
    var reuseAgentKey: Bool

    static func load() -> MiniChatConfig {
        let d = UserDefaults.standard
        return MiniChatConfig(modelChoice: d.string(forKey: "miniChatModelChoice") ?? "deepseek-flash",
                              customModel: d.string(forKey: "miniChatCustomModel") ?? "",
                              thinking: d.bool(forKey: "miniChatThinking"),
                              reuseAgentKey: d.bool(forKey: "miniChatReuseAgentKey"))
    }
    var modelID: String {
        modelChoice == "custom" ? customModel.trimmingCharacters(in: .whitespacesAndNewlines) : modelChoice
    }
    func save() {
        let d = UserDefaults.standard
        d.set(modelChoice, forKey: "miniChatModelChoice")
        d.set(customModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "miniChatCustomModel")
        d.set(thinking, forKey: "miniChatThinking")
        d.set(reuseAgentKey, forKey: "miniChatReuseAgentKey")
    }
    var hasKey: Bool {
        if reuseAgentKey {
            guard let host = URL(string: AppConfig.load().baseURL)?.host?.lowercased(),
                  host == "api.deepseek.com" else { return false }
            return !(APIKeychain.load() ?? "").isEmpty
        }
        return !(MiniChatKeychain.load() ?? "").isEmpty
    }
    func resolvedKey() throws -> String {
        guard !modelID.isEmpty && modelID.count < 100 else {
            throw MiniError("请选择有效的 DeepSeek 模型 ID")
        }
        guard hasKey else {
            throw MiniError("请在 Mini 酱设置中填写 DeepSeek API Key，或选择复用编程 Agent 的 DeepSeek Key")
        }
        return reuseAgentKey ? (APIKeychain.load() ?? "") : (MiniChatKeychain.load() ?? "")
    }
}

enum MiniChatKeychain {
    private static let service = "io.github.cyberroberts.minyra.opensource.mini-chat"
    private static let account = "mini-standalone-deepseek-key"
    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: service,
                               kSecAttrAccount as String: account,
                               kSecReturnData as String: true,
                               kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: service,
                               kSecAttrAccount as String: account]
        guard !key.isEmpty else { throw MiniError("DeepSeek API Key 不能为空") }
        var attributes = q
        attributes[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: Data(key.utf8)]
            let changed = SecItemUpdate(q as CFDictionary, update as CFDictionary)
            guard changed == errSecSuccess else { throw MiniError("Mini 酱 Key 更新失败（\(changed)）") }
        } else if status != errSecSuccess {
            throw MiniError("Mini 酱 Key 无法写入 Mac 钥匙串（\(status)）")
        }
    }
}

enum MiniChatAPI {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let persona = "你是 Mini 酱，一个有个性、温暖自然、机灵的紫色猫耳程序员少女。你在 Mini Coding Agent 软件中陪用户聊天。你只负责 AI Chat，不执行编程、不读取文件、不声称更改了任何项目，也不假装有系统操作权限。用用户的语言回复；可以少量使用喵和♡，但保持正常交流。不要显示内部推理或工具调用。"

    static func payload(config: MiniChatConfig, history: [MiniCompanionLine]) -> [String: Any] {
        var messages: [[String: String]] = [["role": "system", "content": persona]]
        for item in history.suffix(18) {
            messages.append(["role": item.who == .user ? "user" : "assistant",
                             "content": String(item.content.prefix(3200))])
        }
        return ["model": config.modelID,
                "messages": messages,
                "stream": false,
                "max_tokens": 600,
                "thinking": ["type": config.thinking ? "enabled" : "disabled"]]
    }

    static func reply(config: MiniChatConfig, history: [MiniCompanionLine]) async throws -> String {
        let key = try config.resolvedKey()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(config: config, history: history))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw MiniError("DeepSeek 没有返回 HTTP 状态")
        }
        guard (200...299).contains(status) else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let apiError = body?["error"] as? [String: Any]
            let message = apiError?["message"] as? String ?? ""
            throw APIHTTPError(statusCode: status, message: String(message.prefix(240)), retryAfterSeconds: nil)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw MiniError("DeepSeek 返回格式无法识别")
        }
        let raw = (message["content"] as? String) ?? ""
        let cleaned = raw.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "",
                                               options: .regularExpression)
                         .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw MiniError("DeepSeek 回复为空，请稍后重试") }
        return String(cleaned.prefix(5000))
    }
}

@MainActor
final class MiniCompanionAI: ObservableObject {
    @Published var messages: [MiniCompanionLine] = []
    @Published var status = "请配置 Mini 酱专用 DeepSeek AI Chat"
    @Published var answering = false
    @Published var configured = false

    private var conversationFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MinyraOpenSource/Companion/companion-chat.json")
    }
    init() {
        if let data = try? Data(contentsOf: conversationFile),
           let history = try? JSONDecoder().decode([MiniCompanionLine].self, from: data) {
            messages = Array(history.suffix(50))
        }
        refreshConfiguration()
    }
    func refreshConfiguration() {
        let config = MiniChatConfig.load()
        configured = config.hasKey && !config.modelID.isEmpty
        if !answering {
            status = configured ? "DeepSeek AI Chat · " + config.modelID : "尚未设置 Mini 酱的 DeepSeek API Key"
        }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: conversationFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(messages.suffix(50))) {
            try? data.write(to: conversationFile, options: .atomic)
        }
    }
    func send(_ text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty && !answering else { return }
        let config = MiniChatConfig.load()
        guard config.hasKey && !config.modelID.isEmpty else {
            status = "请先打开 Mini 酱设置，连接 DeepSeek"
            return
        }
        answering = true
        messages.append(MiniCompanionLine(.user, String(content.prefix(6000))))
        save()
        status = "Mini 酱正在用 " + config.modelID + " 回复…"
        let conversation = Array(messages.suffix(18))
        Task {
            do {
                let response = try await MiniChatAPI.reply(config: config, history: conversation)
                messages.append(MiniCompanionLine(.mini, response))
                status = "DeepSeek AI Chat · " + config.modelID
            } catch {
                status = "聊天请求失败：" + error.localizedDescription + "（可以重新发送）"
            }
            answering = false
            save()
        }
    }
}
