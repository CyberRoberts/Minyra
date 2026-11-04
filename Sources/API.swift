import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A server-side outage is not evidence of a coding loop.
struct APIHTTPError: LocalizedError {
    let statusCode: Int
    let message: String
    let retryAfterSeconds: Int?

    var isTransient: Bool { [408, 429, 500, 502, 503, 504, 529].contains(statusCode) || (500...599).contains(statusCode) }
    var retryDelaySeconds: Int { min(90, max(3, retryAfterSeconds ?? 3)) }
    var errorDescription: String? {
        let summary: String
        switch statusCode {
        case 401, 403: summary = "API Key 无效或无权限，请检查设置"
        case 429: summary = "API 请求过于频繁，服务商暂时限流"
        case 503: summary = "DeepSeek 等 API 服务端暂时繁忙（HTTP 503）"
        case 502, 504: summary = "API 服务网关暂时不可用（HTTP \(statusCode)）"
        case 500...599: summary = "API 服务器暂时异常（HTTP \(statusCode)）"
        default: summary = "API 请求失败（HTTP \(statusCode)）"
        }
        let sanitized = String(message.prefix(320))
        return summary + (sanitized.isEmpty ? "" : "：" + sanitized)
    }
}

struct AIReply {
    let message: [String: Any]
    let text: String
    let toolCalls: [[String: Any]]
    let tokensIn: Int?
    let tokensOut: Int?
}

// The offline delivery test executes the real AgentCore loop and real local
// tools using deterministic mock responses. It NEVER calls the network or
// reads a personal API key. Enabled only by an explicit CLI test argument.
@MainActor
enum MiniAgentE2EFixture {
    static var replies: [AIReply] = []
    static var requests = 0
    static func makeCall(_ name: String, _ payload: [String: Any], _ id: String) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ["id": id, "type": "function",
                "function": ["name": name, "arguments": String(decoding: data, as: UTF8.self)]]
    }
    static func enqueue(_ calls: [[String: Any]]) {
        replies.append(AIReply(message: ["role": "assistant", "tool_calls": calls],
                               text: "", toolCalls: calls, tokensIn: 120, tokensOut: 110))
    }
    static func consume() throws -> AIReply {
        requests += 1
        guard !replies.isEmpty else { throw MiniError("E2E fixture exhausted before Completed") }
        return replies.removeFirst()
    }
}

enum AIService {
    static let toolDefinitions: [[String: Any]] = [
        ["type": "function", "function": ["name": "list_files", "description": "List the project files and source directory structure. Relative paths only.",
            "parameters": ["type": "object", "properties": ["path": ["type": "string", "description": "Relative folder, defaults to ."]]]]],
        ["type": "function", "function": ["name": "read_file", "description": "Read a numbered source-file section. Use start_line/end_line to inspect large files piece by piece; do not read secrets.",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"], "start_line": ["type": "integer", "description": "First line, 1-based, default 1"], "end_line": ["type": "integer", "description": "Last line, maximum 221 lines per call"]], "required": ["path"]]]],
        ["type": "function", "function": ["name": "write_file", "description": "Create a file or replace a full file inside the project. Read an existing file before overwriting.",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]]],
        ["type": "function", "function": ["name": "replace_in_file", "description": "Replace exactly one occurrence in an existing source file.",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"], "old_text": ["type": "string"], "new_text": ["type": "string"]], "required": ["path", "old_text", "new_text"]]]],
        ["type": "function", "function": ["name": "report_progress", "description": "User-visible brief work log. Report observed results, current goal and next step. DO NOT reveal private chain-of-thought. Use at meaningful milestones and after failed tests.",
            "parameters": ["type": "object", "properties": ["phase": ["type": "string"], "observation": ["type": "string"], "next": ["type": "string"]], "required": ["phase", "observation", "next"]]]],
        ["type": "function", "function": ["name": "set_acceptance_plan", "description": "At the beginning of a coding task register concrete testable requirements from the user's request. Existing requirements cannot be removed; each one gets a stable C-number. Avoid unverifiable claims.",
            "parameters": ["type": "object", "properties": ["requirements": ["type": "array", "items": ["type": "string"]]], "required": ["requirements"]]]],
        ["type": "function", "function": ["name": "finish_task", "description": "Mark software development complete only after actual build/test checks pass following last edits. Supply actual created output paths, verification evidence, and remaining caveats. The app verifies files/test status before accepting.",
            "parameters": ["type": "object", "properties": ["summary": ["type": "string"], "artifacts": ["type": "array", "items": ["type": "string"]], "checks": ["type": "array", "items": ["type": "object", "properties": ["criterion_id": ["type": "string"], "argv": ["type": "array", "items": ["type": "string"]], "cwd": ["type": "string"]], "required": ["criterion_id", "argv"]]], "remaining": ["type": "string"]], "required": ["summary", "artifacts", "checks", "remaining"]]]],
        ["type": "function", "function": ["name": "run_command", "description": "Run tests or a build inside the local project. Provide argv array, not shell string. Run enough tests to validate results.",
            "parameters": ["type": "object", "properties": ["argv": ["type": "array", "items": ["type": "string"]], "cwd": ["type": "string", "description": "Relative project directory, defaults to ."]], "required": ["argv"]]]]
    ]

    static func endpoint(from base: String) throws -> URL {
        let string = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = string.hasSuffix("/chat/completions") ? string : string + "/chat/completions"
        guard let url = URL(string: full), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw MiniError("请输入 HTTPS API 地址；本地服务可以用 http://localhost")
        }
        return url
    }
    static func send(settings: AppConfig, key: String, history: [[String: Any]], tools: Bool = true,
                     route: MiniRoute? = nil) async throws -> AIReply {
        if CommandLine.arguments.contains("--agent-e2e-test") {
            return try await MiniAgentE2EFixture.consume()
        }
        let url = try endpoint(from: settings.baseURL)
        var payload: [String: Any] = ["model": route?.model ?? settings.model,
                                       "messages": history, "stream": false,
                                       "max_tokens": route?.maxTokens ?? 8192]
        if let effort = route?.effort { payload["reasoning_effort"] = effort }
        if tools { payload["tools"] = toolDefinitions; payload["tool_choice"] = "auto" }
        let body = try JSONSerialization.data(withJSONObject: payload)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 150
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("MiniCodingAgent/3.1.4", forHTTPHeaderField: "User-Agent")
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let resp = response as? HTTPURLResponse else { throw MiniError("API 未返回 HTTP 状态") }
        guard (200...299).contains(resp.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let obj = json?["error"] as? [String: Any]
            let brief = obj?["message"] as? String ?? String(decoding: data.prefix(700), as: UTF8.self)
            // Preserve the HTTP status so the agent can distinguish a server outage
            // from an actual repeating implementation/test failure.
            let retryAfter = resp.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw APIHTTPError(statusCode: resp.statusCode, message: String(brief.prefix(500)), retryAfterSeconds: retryAfter)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw MiniError("当前 API 不兼容 Chat Completions 接口，请检查地址及模型")
        }
        let content: String
        if let s = msg["content"] as? String { content = s }
        else if let blocks = msg["content"] as? [[String: Any]] { content = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        else { content = "" }
        let usage = json["usage"] as? [String: Any]
        return AIReply(message: msg, text: content, toolCalls: msg["tool_calls"] as? [[String: Any]] ?? [],
            tokensIn: usage?["prompt_tokens"] as? Int, tokensOut: usage?["completion_tokens"] as? Int)
    }
}
