import Foundation

// Runs outside the model. A tool call asking to finish is only a proposal, never a completion decision.
enum TaskLifecycle: String, Codable {
    case idle, running, blocked, completed
}

struct AcceptanceCriterion: Codable, Equatable, Identifiable {
    var id: String
    var requirement: String
}

struct AcceptanceCheck: Codable {
    var criterionID: String
    var argv: [String]
    var cwd: String
    var result: String
    var revision: Int
    var date: Date
}

struct AcceptanceSupervisor: Codable {
    var status: TaskLifecycle = .idle
    var criteria: [AcceptanceCriterion] = []
    var confirmedChecks: [AcceptanceCheck] = []
    var completedArtifacts: [String] = []
    var blockedReason = ""
    var failuresAtRevision: Int = -1
    var lastFailure = ""
    var identicalFailureCount = 0

    mutating func startFresh() {
        status = .running
        criteria = []
        confirmedChecks = []
        completedArtifacts = []
        blockedReason = ""
        failuresAtRevision = -1
        lastFailure = ""
        identicalFailureCount = 0
    }

    mutating func resume() {
        status = .running
        blockedReason = ""
        identicalFailureCount = 0 // A deliberate user retry should not inherit a preexisting block.
    }

    mutating func block(_ reason: String) {
        status = .blocked
        blockedReason = String(reason.prefix(420))
    }

    mutating func registerPlan(_ requirements: [String]) -> String? {
        if requirements.isEmpty { return "请列出至少一条可验收的具体要求。" }
        if requirements.count > 16 { return "请把验收条目合并为不超过 16 条可实际检查的功能。" }
        // Additions are allowed, but previously recorded requirements cannot be silently removed.
        var added = 0
        for item in requirements {
            let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count < 6 || cleaned.count > 280 { return "验收条目需为 6–280 字符的具体、可验证目标。" }
            if !criteria.contains(where: { $0.requirement == cleaned }) {
                if criteria.count >= 16 { return "本任务已存在 16 个验收目标。" }
                criteria.append(AcceptanceCriterion(id: "C\(criteria.count + 1)", requirement: cleaned))
                added += 1
            }
        }
        return added == 0 ? nil : "已记录 \(added) 条验收目标，不能在任务结束前悄悄删除。"
    }

    func preflight(artifacts: [String], checks: [AcceptanceCheckRequest], changedRevision: Int) -> String? {
        if criteria.isEmpty { return "尚未建立验收计划。请先调用 set_acceptance_plan 列出用户需求的可检查目标。" }
        if changedRevision <= 0 { return "本任务还没有实际修改或创建任何项目文件。" }
        if artifacts.isEmpty { return "没有提供要交付的项目文件路径。" }
        if checks.isEmpty { return "没有提供可由本地程序独立重跑的验证命令。" }
        for criterion in criteria {
            if !checks.contains(where: { $0.criterionID == criterion.id }) {
                return "验收目标 \(criterion.id) 尚无自动验证命令：\(criterion.requirement)"
            }
        }
        if checks.count > 24 { return "一次验收命令过多，请合并重复检查。" }
        for check in checks {
            if !check.plausibleVerification { return "验收命令不是实际编译或测试：\(check.argv.joined(separator: " "))" }
            if !criteria.contains(where: { $0.id == check.criterionID }) {
                return "验收命令对应的目标编号不存在：\(check.criterionID)"
            }
            if check.argv.isEmpty || check.argv.count > 40 || check.argv.joined().count > 2500 {
                return "验收命令参数缺失或过长：\(check.criterionID)"
            }
        }
        return nil
    }

    // Repeatedly claiming completion without changing the project is an actual no-progress loop.
    mutating func rejection(_ reason: String, revision: Int) -> Bool {
        let key = String(reason.prefix(260))
        if revision == failuresAtRevision && key == lastFailure { identicalFailureCount += 1 }
        else { failuresAtRevision = revision; lastFailure = key; identicalFailureCount = 1 }
        if identicalFailureCount >= 3 {
            block("同一验收失败已连续出现 3 次，且项目没有新的有效修改：\(key)")
            return true
        }
        return false
    }

    mutating func complete(artifacts: [String], checks: [AcceptanceCheck]) {
        status = .completed
        completedArtifacts = artifacts
        confirmedChecks = checks
        blockedReason = ""
        identicalFailureCount = 0
    }
}

struct AcceptanceCheckRequest {
    let criterionID: String
    let argv: [String]
    let cwd: String

    var plausibleVerification: Bool {
        guard let cmd = argv.first else { return false }
        let script = argv.dropFirst().first ?? ""
        if ["python", "python3"].contains(cmd) {
            return script.hasSuffix(".py") || (script == "-m" && argv.count >= 3 && ["pytest", "compileall", "unittest", "py_compile"].contains(argv[2]))
        }
        if ["node"].contains(cmd) { return script.hasSuffix(".js") || script.hasSuffix(".mjs") }
        if ["npm", "pnpm", "yarn", "bun"].contains(cmd) { return argv.contains(where: { ["test", "build", "check", "lint"].contains($0) }) }
        if ["swift", "cargo", "go", "dotnet"].contains(cmd) { return argv.contains(where: { ["test", "build", "run"].contains($0) || $0.hasSuffix(".swift") }) }
        return ["pytest", "swiftc", "xcodebuild", "tsc", "make", "cmake", "clang", "clang++", "gcc", "g++", "javac"].contains(cmd)
    }

    static func fromJSON(_ value: Any?) -> [AcceptanceCheckRequest]? {
        guard let list = value as? [[String: Any]] else { return nil }
        var checks: [AcceptanceCheckRequest] = []
        for object in list {
            guard let id = object["criterion_id"] as? String,
                  let argv = object["argv"] as? [String] else { return nil }
            checks.append(AcceptanceCheckRequest(criterionID: id, argv: argv, cwd: object["cwd"] as? String ?? "."))
        }
        return checks
    }
}
