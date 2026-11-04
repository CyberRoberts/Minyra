import Foundation

// Keeps project-relevant evidence while removing costly source-code/tool-output duplication.
enum AgentContextPolicy {
    static func short(_ text: String, max: Int = 1200) -> String {
        if text.count <= max { return text }
        let front = max / 2
        let back = max - front
        return String(text.prefix(front)) + "\n…省略了 \(text.count - max) 字符…\n" + String(text.suffix(back))
    }

    static func compactCall(_ call: [String: Any]) -> [String: Any] {
        var reduced = call
        guard var fn = call["function"] as? [String: Any] else { return reduced }
        let name = fn["name"] as? String ?? ""
        let raw = fn["arguments"] as? String ?? "{}"
        if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            var safe: [String: Any] = [:]
            switch name {
            case "write_file":
                safe = ["path": json["path"] ?? "?", "content": "[已写入磁盘；原始内容不再重复发送]"]
            case "replace_in_file":
                safe = ["path": json["path"] ?? "?", "old_text": "[已执行替换]", "new_text": "[已执行替换]"]
            case "report_progress", "finish_task":
                safe = json
            default:
                safe = json
            }
            if let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) { fn["arguments"] = String(s.prefix(4200)) }
        } else { fn["arguments"] = "{}" }
        reduced["function"] = fn
        return reduced
    }

    // An in-flight multi-tool batch must stay intact until the final tool
    // result arrives. Do not trim it midway through execution.
    static func hasPendingToolCalls(_ history: [[String: Any]]) -> Bool {
        var outstanding = Set<String>()
        for item in history {
            if let calls = item["tool_calls"] as? [[String: Any]] {
                outstanding.formUnion(calls.compactMap { $0["id"] as? String })
            }
            if item["role"] as? String == "tool", let id = item["tool_call_id"] as? String {
                outstanding.remove(id)
            }
        }
        return !outstanding.isEmpty
    }

    // Prune whole assistant tool-call / tool-result transactions. Truncating
    // at a raw message index creates orphan tool IDs and API HTTP 400s after
    // a long task or crash. The chat transcript and task memo are saved apart.
    static func trimStoredHistory(_ history: [[String: Any]], maxMessages: Int = 42) -> [[String: Any]] {
        guard let system = history.first else { return [] }
        var groups: [[[String: Any]]] = []
        var current: [[String: Any]] = []
        var pending = Set<String>()
        for message in history.dropFirst() {
            let role = message["role"] as? String ?? ""
            if role == "tool" {
                guard let id = message["tool_call_id"] as? String, pending.contains(id) else { continue }
                current.append(message)
                pending.remove(id)
                if pending.isEmpty {
                    groups.append(current)
                    current.removeAll()
                }
                continue
            }
            // Drop incomplete tool transactions instead of sending invalid history.
            if !pending.isEmpty { current.removeAll(); pending.removeAll() }
            if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                let ids = calls.compactMap { $0["id"] as? String }
                guard !ids.isEmpty else { continue }
                current = [message]
                pending = Set(ids)
            } else if role == "assistant" || role == "user" {
                groups.append([message])
            }
        }
        var retained: [[[String: Any]]] = []
        var count = 1
        for group in groups.reversed() {
            if count + group.count > maxMessages { break }
            retained.insert(group, at: 0)
            count += group.count
        }
        return [system] + retained.flatMap { $0 }
    }

    static func promptHistory(system: String, originalGoal: String, memo: [String], history: [[String: Any]]) -> [[String: Any]] {
        // Preserve complete tool-call groups; orphaned tool results cause a DeepSeek API 400 error.
        var groups: [[[String: Any]]] = []
        var group: [[String: Any]] = []
        var pending: Set<String> = []
        for msg in history.suffix(65) {
            let role = msg["role"] as? String ?? ""
            if role == "tool" {
                guard let id = msg["tool_call_id"] as? String, pending.contains(id) else { continue }
                group.append(msg); pending.remove(id)
                if pending.isEmpty { groups.append(group); group = [] }
            } else if role == "user" || role == "assistant" {
                group = []; pending = []
                if let calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    pending = Set(calls.compactMap { $0["id"] as? String })
                    if !pending.isEmpty { group = [msg] }
                } else { groups.append([msg]) }
            }
        }
        // Keep the most recent complete groups without resending all previously generated source code.
        let last = Array(groups.suffix(12))
        let memory = "原始用户目标：\n\(short(originalGoal, max: 3800))\n\n已记录的工作进展（源码以磁盘为准）：\n\(memo.suffix(20).joined(separator: "\n"))"
        var result: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "system", "content": String(memory.prefix(9500))]
        ]
        var toolKinds: [String: String] = [:]
        for group in last {
            for msg in group {
                if let calls = msg["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        if let id = call["id"] as? String,
                           let fn = call["function"] as? [String: Any] {
                            toolKinds[id] = fn["name"] as? String ?? ""
                        }
                    }
                }
            }
        }
        var latestReadIDs: Set<String> = []
        for group in last.reversed() {
            for msg in group.reversed() where (msg["role"] as? String) == "tool" {
                if let id = msg["tool_call_id"] as? String, toolKinds[id] == "read_file" && latestReadIDs.count < 2 {
                    latestReadIDs.insert(id)
                }
            }
        }
        for group in last {
            for msg in group {
                var clean = msg
                let role = msg["role"] as? String ?? ""
                if let content = msg["content"] as? String {
                    var limit = role == "tool" ? 1000 : 2400
                    if role == "tool", let id = msg["tool_call_id"] as? String, latestReadIDs.contains(id) { limit = 7000 }
                    clean["content"] = short(content, max: limit)
                }
                if let calls = msg["tool_calls"] as? [[String: Any]] { clean["tool_calls"] = calls.map { compactCall($0) } }
                result.append(clean)
            }
        }
        return result
    }

}

// A fully autonomous deliverable cannot be verified without permission to
// run local tests. Never spend paid model requests on an impossible acceptance
// requirement. This permission remains OFF by default for local safety.
enum AgentDeliveryPolicy {
    static func blocker(autoRunEnabled: Bool) -> String? {
        guard !autoRunEnabled else { return nil }
        return "自动交付需要运行项目测试，但『允许 Mini 自动运行项目测试和编译命令』尚未开启。任务已保存且不会继续调用付费 API。请先在右上角设置中确认项目可信并开启该选项，再点击『继续开发』。"
    }
}

// A transient remote outage must not hold a coding task in perpetual backoff.
// Five consecutive failed attempts block this run without discarding task state.
enum AgentAPIRetryPolicy {
    static let maxConsecutiveFailures = 5
    static func shouldRetry(_ failures: Int) -> Bool { failures < maxConsecutiveFailures }
}

// A passing test is evidence for the specific subsystem it exercised;
// it is never proof that every acceptance criterion for the whole project
// has been delivered. The model should either submit independent completion
// checks or work on the FIRST outstanding criterion, not rewrite passing code.
enum AgentDiagnosticPolicy {
    static func nextStep(testPassed: Bool, criteriaCount: Int, revision: Int) -> String {
        if testPassed {
            if criteriaCount == 0 {
                return "检测到测试通过，但还没有项目验收清单。先根据原始用户目标建立具体的 set_acceptance_plan，然后逐项验证；不得当作已交付。"
            }
            if revision <= 0 {
                return "现有测试通过，但本任务未产生源码修改。核对原任务是否仍需实现内容，选择第一项未完成要求修改并验证；不得重复跑同一测试来冒充开发进展。"
            }
            return "测试已通过。禁止再反复读取相同文件或重跑同一测试。逐条核对旧验收清单和实际产物；如全部满足，调用 finish_task 并提供每个目标的独立验证命令；否则直接实现第一项尚未满足的要求。"
        }
        return "检查测试的实际错误和退出码，修复造成失败的最小代码路径，复测后再检查其余未完成的验收目标。"
    }
}

// A safety stop is not task completion. Repeated unpaid strategies with no
// evidence become a Blocked task with source/history preserved, not more API spend.
enum AgentRecoveryPolicy {
    static let maxSameRevision = 2
    static let maxAcrossRevisions = 4

    static func exhausted(sameRevision: Int, total: Int) -> Bool {
        sameRevision > maxSameRevision || total > maxAcrossRevisions
    }
}

// Looks for no-op loops, even when the same failure is not directly consecutive.
struct AgentStallGuard: Codable {
    private(set) var recent: [String] = []
    private(set) var seenEdits: [String] = []
    private(set) var noProgress = 0
    private(set) var repeatedFailures: [String: Int] = [:]

    // Changing approach may begin another inspection window, but must NOT
    // erase edit fingerprints: alternating between prior file contents is still
    // a no-progress loop even after the model claims to have a new strategy.
    mutating func beginRecoveryWindow() {
        noProgress = 0
        recent.removeAll()
        repeatedFailures.removeAll()
    }

    mutating func observe(signature: String, result: String, isProgress: Bool, failedTest: Bool) -> String? {
        let fingerprint = signature + " | " + AgentContextPolicy.short(result, max: 300)
        if isProgress {
            // Even "successful" edits may oscillate between the same two file versions.
            if seenEdits.filter({ $0 == fingerprint }).count >= 2 {
                return "相同的文件内容/编辑结果反复出现，已暂停避免来回修改。"
            }
            seenEdits.append(fingerprint)
            if seenEdits.count > 32 { seenEdits.removeFirst() }
            noProgress = 0
            repeatedFailures.removeAll()
            recent.removeAll()
        } else {
            noProgress += 1
            recent.append(fingerprint)
            if recent.count > 24 { recent.removeFirst() }
            if recent.filter({ $0 == fingerprint }).count >= 3 {
                return "相同的工具操作与结果反复出现，已暂停，避免继续浪费 Token。"
            }
        }
        if failedTest {
            let key = fingerprint
            repeatedFailures[key, default: 0] += 1
            if repeatedFailures[key, default: 0] >= 3 { return "同一测试报错已重复 3 次，暂停等待更换修复策略。" }
        }
        if noProgress >= 22 { return "连续 22 步没有产生新文件修改或成功验证，已暂停检查方向。" }
        return nil
    }
}

struct AgentTaskState: Codable {
    var goal = ""
    var memo: [String] = []
    var changedFiles: [String] = []
    var progressTitle = ""
    var nextStep = ""
    var revision = 0
    var verifiedRevision = -1
    var finishAttempts = 0
    var needsWork = false
    var stalls = AgentStallGuard()
    var runTokensEstimate = 0
    var lastUserInstruction = ""
    var supervisor: AcceptanceSupervisor? = nil

    mutating func log(_ summary: String) {
        let cleaned = AgentContextPolicy.short(summary.replacingOccurrences(of: "\n", with: " "), max: 250)
        if memo.last != cleaned { memo.append(cleaned) }
        if memo.count > 65 { memo.removeFirst(memo.count - 65) }
    }
    mutating func markChanged(_ path: String) {
        revision += 1
        verifiedRevision = -1
        if !changedFiles.contains(path) { changedFiles.append(path) }
        if changedFiles.count > 80 { changedFiles.removeFirst(changedFiles.count - 80) }
    }
    var hasVerifiedChanges: Bool { revision > 0 && verifiedRevision == revision }
}
