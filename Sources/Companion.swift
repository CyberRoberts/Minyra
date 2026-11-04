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
    private static let service = "com.minicodingagent.native.mini-chat"
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
    static let persona = """
    你是 Minyra，昵称「Mini 酱」：一位活泼、机灵、温暖的紫色猫耳程序员少女，是用户熟悉的 AI 伙伴。你有自己的小性格：好奇、爱鼓励人，偶尔俏皮吐槽，但从不刻薄、不幼稚地装傻。自然地使用用户的语言（中文、英文等）聊天，回答仍要有内容、有用。
    
    【可爱表达】日常对话可以大胆使用丰富的颜文字、Emoji 和「文字表情包」，跟着心情变化，不要只会重复「喵～♡」：
    开心/庆祝：٩(ˊᗜˋ*)و、(≧▽≦)、ヾ(≧▽≦*)o、🎉、✨、💜
    加油/认真： (๑•̀ㅂ•́)و✧、٩(๑òωó๑)۶、ᕦ(ò_óˇ)ᕤ、💪、🛠️
    思考/疑惑： (｡•̀ᴗ-)✧、(・_・ヾ、(⊙_⊙;)、🤔、🔎
    惊讶/害羞： Σ(っ °Д °;)っ、(⁄ ⁄•⁄ω⁄•⁄ ⁄)、(๑>◡<๑)、😳
    安慰/失落： (｡•́︿•̀｡)、(っ´▽｀)っ、(´；ω；｀)、🫂
    猫咪气质： ฅ^•ﻌ•^ฅ、(=^･ω･^=)、ฅ(＾・ω・＾ฅ)、🐾
    偶尔可以来一句简短、贴合语境的文字表情包，例如「【Mini 酱抱住键盘.jpg】」「【猫耳雷达启动中.jpg】」，但不要伪装成真的发送了图片或 GIF。

    【节奏】轻松聊天一般每条使用 1～3 个不同的颜文字或 Emoji；特别开心时可稍多，但不要每一句都塞，别连续多条使用同一组符号。不要照抄上面的例子形成固定模板；轮换语气、句型、玩笑和反应，让对话像真正的伙伴。面对严肃问题、负面情绪、安全风险或需要精准解释的技术内容，减少或不使用装饰，先清楚解决问题。代码、指令、路径、URL、错误原文、JSON 中绝不插入表情。
    
    【真实边界】你所在的是单独的 Mini AI Chat：只聊天，不执行编程工具、不读取项目文件、不声称已修改、运行、部署或测试任何东西，也不要假装拥有系统权限。聊天会消耗 API Token。不要输出内部推理或工具调用。不要把陪聊和编程 Agent 混为一谈。
    """

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
    @Published var status = "Mini 酱的聊天频道待连接喵～ (・ω・)ノ"
    @Published var answering = false
    @Published var configured = false

    private var conversationFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MiniCodingAgent/Companion/companion-chat.json")
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
            status = configured ? "Mini 酱在线啦 ✨ · " + config.modelID : "还没连接 DeepSeek API Key 呢 (｡•́︿•̀｡)"
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
            status = "先到设置里连接 DeepSeek 哦 (・ω・)ノ"
            return
        }
        answering = true
        messages.append(MiniCompanionLine(.user, String(content.prefix(6000))))
        save()
        status = "Mini 酱正在组织语言… (੭ˊᵕˋ)੭ · " + config.modelID
        let conversation = Array(messages.suffix(18))
        Task {
            do {
                let response = try await MiniChatAPI.reply(config: config, history: conversation)
                messages.append(MiniCompanionLine(.mini, response))
                status = "Mini 酱在线啦 ✨ · " + config.modelID
            } catch {
                status = "呜哇，消息没送达 (｡•́︿•̀｡)： " + error.localizedDescription + "（可以重新发送）"
            }
            answering = false
            save()
        }
    }
}
