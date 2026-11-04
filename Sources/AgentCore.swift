import Foundation
import AppKit
import Combine
import Darwin

struct ChatLine: Identifiable, Codable {
    enum Kind: String, Codable { case user, assistant, info, error, progress }
    let id: UUID
    let kind: Kind
    let message: String
    init(_ kind: Kind, _ message: String) { id = UUID(); self.kind = kind; self.message = message }
}

final class LocalCommandRunner {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p = p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }
    func run(_ argv: [String], cwd: URL, projectRoot: URL) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let wrapped: [String]
                let env: [String: String]
                let canonicalCwd: URL
                do {
                    let physicalRoot = try ProjectExecutionSandbox.physicalURL(projectRoot)
                    canonicalCwd = try ProjectExecutionSandbox.physicalURL(cwd)
                    guard canonicalCwd.path == physicalRoot.path ||
                          canonicalCwd.path.hasPrefix(physicalRoot.path + "/") else {
                        throw MiniError("沙箱工作目录超出了授权项目")
                    }
                    wrapped = try ProjectExecutionSandbox.wrappedArguments(argv, projectRoot: projectRoot)
                    env = try ProjectExecutionSandbox.environment(projectRoot: projectRoot)
                } catch {
                    cont.resume(returning: "命令失败：缺少有效的操作系统执行隔离，已拒绝不安全运行：" + error.localizedDescription)
                    return
                }
                let p = Process()
                // Swift Process.currentDirectoryURL may be applied differently
                // from posix_spawn cwd, particularly before sandbox-exec.
                // Perform the literal cd BEFORE enabling Seatbelt; no model
                // text is ever interpolated into this fixed shell program.
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "cd \"$1\" && shift && exec \"$@\"", "mini-cwd",
                               canonicalCwd.path, ProjectExecutionSandbox.executable] + wrapped
                var scopedEnv = env
                scopedEnv["PWD"] = canonicalCwd.path
                p.environment = scopedEnv
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                let outputLock = NSLock()
                var collected = Data()
                var overflow = false
                // Reading a pipe to EOF before waiting for the parent process
                // can hang forever when a test forks a child that keeps stdout
                // open. Drain asynchronously and wait ONLY for the process.
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    outputLock.lock()
                    if collected.count < 24_000 {
                        collected.append(chunk.prefix(24_000 - collected.count))
                    } else { overflow = true }
                    outputLock.unlock()
                }
                self.lock.lock(); let wasCancelled = self.cancelled
                if !wasCancelled { self.process = p }
                self.lock.unlock()
                if wasCancelled { cont.resume(returning: "已取消命令"); return }
                do {
                    try p.run()
                    let timeout = DispatchWorkItem {
                        if p.isRunning {
                            p.terminate()
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                            }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: timeout)
                    p.waitUntilExit()
                    timeout.cancel()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    pipe.fileHandleForReading.closeFile()
                    outputLock.lock()
                    let output = collected
                    let truncated = overflow
                    outputLock.unlock()
                    self.lock.lock(); let stopped = self.cancelled; self.process = nil; self.lock.unlock()
                    let label = stopped ? "手动停止" : "退出码 \(p.terminationStatus)"
                    cont.resume(returning: "\(label)\n" + (output.isEmpty ? "(没有输出)" : String(decoding: output, as: UTF8.self)) + (truncated ? "\n…命令输出已截断" : ""))
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    pipe.fileHandleForReading.closeFile()
                    self.lock.lock(); self.process = nil; self.lock.unlock()
                    cont.resume(returning: "命令失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

@MainActor
final class AgentCore: ObservableObject {
    @Published var chat: [ChatLine] = []
    @Published var running = false
    @Published var paused = false
    @Published var activity = "可以开始开发了"
    @Published var toolOperations = 0
    @Published var apiCalls = 0
    @Published var tokensInput = 0
    @Published var tokensOutput = 0
    @Published var usageAvailable = false
    @Published var routingStatus = "模型：待命"
    @Published var workspace: MiniProject = .automatic()
    @Published private(set) var taskState = AgentTaskState()
    @Published var budgetNotice = ""
    @Published var waitingForAPI = false
    @Published var queuedInstructions: [String] = []

    private var history: [[String: Any]] = []
    private let executor = LocalCommandRunner()
    // Used solely by the opt-in --agent-e2e-test executable path.
    private var e2eKey: String? = nil
    func enableE2EKeyForDeliveryTest() {
        guard CommandLine.arguments.contains("--agent-e2e-test") else { return }
        e2eKey = "offline-test-credential-never-sent"
    }
    private var currentJob: Task<Void, Never>?
    private var runningWhenSaved = false
    private var finishedDuringRun = false
    private var recentTestFailures = 0
    private var lastFailureSummary = ""
    private var plannedGoal = ""
    private var diagnosedRevision = -1
    private var proUnavailable = false
    private var previousReadOps: [String: Int] = [:]
    // Auto-replan when progress stalls; do not label a stalled task Completed.
    // A bounded safety interlock prevents unproductive unlimited API spending.
    private var recoveryRevision = -1
    private var recoveryAttempts = 0
    // Count no-progress recovery cycles across file revisions. File changes
    // without successful verification must not reset the cost guard.
    private var stalledRecoveryCycles = 0
    private var automaticDiagnosticRuns = 0
    private var needsDiagnosticOnResume = false
    private var lastFailedTestArgv: [String] = []
    private var lastFailedTestCwd = "."
    private var lastDiagnosticEvidence = ""
    private var lastDiagnosticTrigger = ""
    private var lastDiagnosticPassed = false
    // Stored across restarts: running the SAME passing test on unchanged code
    // is evidence, but not repeated new progress or entire task completion.
    private var verifiedCheckKeys: [String] = []

    init() {
        loadSession()
        if chat.isEmpty { chat.append(ChatLine(.info, "初次见面！Mini 酱来报到啦 ฅ^•ﻌ•^ฅ 💜 告诉我今天要开发什么吧～我会修改项目、运行检查、验证结果；已有项目点 ＋ 添加即可！")) }
    }

    var configured: Bool {
        let c = AppConfig.load()
        return !c.baseURL.isEmpty && !c.model.isEmpty && (e2eKey != nil || APIKeychain.load() != nil)
    }
    var tokensDescription: String { usageAvailable ? "Token \(tokensInput + tokensOutput)" : "Token 未提供" }
    var progressDescription: String { taskState.progressTitle.isEmpty ? (taskState.needsWork ? "等待继续" : "尚未开始") : taskState.progressTitle }
    var projectName: String { workspace.root.lastPathComponent }
    var lifecycle: TaskLifecycle { taskState.supervisor?.status ?? .idle }
    var statusLabel: String {
        switch lifecycle {
        case .idle: return "Ready"
        case .running: return "Running"
        case .blocked: return "Blocked"
        case .completed: return "Completed"
        }
    }


    func openInFinder() { NSWorkspace.shared.open(workspace.root) }
    func attachFiles(_ urls: [URL]) {
        guard !running else { return }
        let result = workspace.importFiles(urls)
        if !result.isEmpty { chat.append(ChatLine(.info, result.joined(separator: "\n"))); saveSession() }
    }
    func attachUsingPanel() {
        guard !running else { return }
        let p = NSOpenPanel()
        p.title = "把现有项目交给 Mini"
        p.message = "选择文件、项目文件夹或 ZIP。Mini 会复制到自己的工作目录，不会改动原件。"
        p.prompt = "添加到对话"
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { attachFiles(p.urls) }
    }
    func openExistingProject() {
        guard !running else { return }
        let p = NSOpenPanel()
        p.title = "打开旧项目"
        p.prompt = "打开这个项目"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            workspace = MiniProject(url)
            workspace.remember()
            resetForProjectChange()
            loadSession()
            if chat.isEmpty { chat = [ChatLine(.info, "项目已打开。直接输入下一步任务。")] }
            saveSession()
        }
    }
    private func resetForProjectChange() {
        history = []
        queuedInstructions = []
        waitingForAPI = false
        chat = []
        paused = false
        runningWhenSaved = false
        apiCalls = 0
        tokensInput = 0
        tokensOutput = 0
        usageAvailable = false
        toolOperations = 0
        routingStatus = "模型：待命"
        recentTestFailures = 0; lastFailureSummary = ""; plannedGoal = ""; diagnosedRevision = -1; proUnavailable = false; previousReadOps = [:]
        activity = "可以开始开发了"
        taskState = AgentTaskState()
        recoveryRevision = -1; recoveryAttempts = 0; stalledRecoveryCycles = 0
        automaticDiagnosticRuns = 0; needsDiagnosticOnResume = false
        lastFailedTestArgv = []; lastFailedTestCwd = "."; lastDiagnosticEvidence = ""
    }
    func newProject() {
        guard !running else { return }
        // Never delete older projects; a new one gets a fresh auto-generated folder.
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let parent = base.appendingPathComponent("MiniAgent 工作站", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = parent.appendingPathComponent("项目-" + formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            workspace = MiniProject(root)
            workspace.remember()
            history = []
            queuedInstructions = []
            waitingForAPI = false
            chat = [ChatLine(.info, "新工作室准备好啦！٩(ˊᗜˋ*)و ✨ 告诉 Mini 酱你的目标吧～")]
            paused = false; runningWhenSaved = false
            apiCalls = 0; tokensInput = 0; tokensOutput = 0; toolOperations = 0; usageAvailable = false
            taskState = AgentTaskState()
            recoveryRevision = -1; recoveryAttempts = 0; stalledRecoveryCycles = 0
        automaticDiagnosticRuns = 0; needsDiagnosticOnResume = false
        lastFailedTestArgv = []; lastFailedTestCwd = "."; lastDiagnosticEvidence = ""
            routingStatus = "模型：待命"
            recentTestFailures = 0; lastFailureSummary = ""; plannedGoal = ""; diagnosedRevision = -1; proUnavailable = false; previousReadOps = [:]
            activity = "等待你下达开发任务"
            saveSession()
        } catch { chat.append(ChatLine(.error, "新项目创建失败：\(error.localizedDescription)")) }
    }

    func start(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        // Conversation stays interactive while API replies are pending, including 503 backoff.
        if running {
            chat.append(ChatLine(.user, prompt))
            queuedInstructions.append(prompt)
            activity = "收到新指令！Mini 酱已经排进待办啦 (๑•̀ㅂ•́)و✧"
            saveSession()
            return
        }
        chat.append(ChatLine(.user, prompt))
        if !configured {
            chat.append(ChatLine(.error, "请先点击右上角齿轮，填写一次 API 地址、模型和 API Key。你的指令已留在聊天记录里。"))
            saveSession(); return
        }
        ensureSystemMessage()
        repairPendingCalls()
        if !taskState.needsWork {
            taskState = AgentTaskState()
            taskState.goal = prompt
            plannedGoal = ""
            recentTestFailures = 0
            diagnosedRevision = -1
            proUnavailable = false
            var gate = AcceptanceSupervisor()
            gate.startFresh()
            taskState.supervisor = gate
        } else if taskState.goal.isEmpty { taskState.goal = prompt }
        if taskState.supervisor == nil {
            var gate = AcceptanceSupervisor()
            gate.startFresh()
            taskState.supervisor = gate
        }
        taskState.lastUserInstruction = prompt
        // A NEW user instruction can provide missing evidence. Automatic
        // replan / pressing Continue does not clear the stall budget.
        recoveryRevision = -1
        recoveryAttempts = 0
        stalledRecoveryCycles = 0
        automaticDiagnosticRuns = 0
        needsDiagnosticOnResume = false
        taskState.needsWork = true
        taskState.log("用户最新指令：" + prompt)
        history.append(["role": "user", "content": prompt])
        paused = true
        saveSession()
        // Do not charge for model requests when final acceptance is impossible.
        if let blocker = AgentDeliveryPolicy.blocker(autoRunEnabled: AppConfig.load().autoRun) {
            blockTask(blocker)
            return
        }
        beginWork()
    }
    func continueWork() {
        guard !running && configured && paused && !history.isEmpty else { return }
        if let blocker = AgentDeliveryPolicy.blocker(autoRunEnabled: AppConfig.load().autoRun) {
            blockTask(blocker)
            return
        }
        // User's Continue authorizes a bounded self-diagnosis of the SAVED task.
        // They must not be required to invent a new requirement or strategy.
        let staleSameRevision = recoveryRevision == taskState.revision ? recoveryAttempts : 0
        let exhausted = AgentRecoveryPolicy.exhausted(sameRevision: staleSameRevision,
                                                       total: stalledRecoveryCycles)
        let blockedReason = taskState.supervisor?.blockedReason ?? ""
        if exhausted || blockedReason.contains("进展") || blockedReason.contains("空转") {
            needsDiagnosticOnResume = true
            lastDiagnosticTrigger = blockedReason
            automaticDiagnosticRuns = 0
            recoveryRevision = -1; recoveryAttempts = 0; stalledRecoveryCycles = 0
            addProgress("正在自动诊断原任务：不需要输入新的要求。")
        }
        repairPendingCalls()
        ensureSystemMessage()
        let wasAPIError = (taskState.supervisor?.blockedReason ?? "").contains("外部 API")
        taskState.supervisor?.resume()
        taskState.stalls = AgentStallGuard()
        let resumePrompt = wasAPIError
            ? "上次仅因外部 API 服务故障而暂停。保持原项目和验收目标，从此前进度继续；先检查磁盘现状，不要无意义重建或重写已经成功的文件。"
            : "继续原任务。用户不需要提供新要求；你应根据保存的项目、已有验收计划和本地诊断自行定位错误并修复。不要重复无效读取或假装交付。"
        history.append(["role": "user", "content": resumePrompt])
        saveSession()
        beginWork()
    }
    func stop() {
        guard running else { return }
        activity = "正在暂停（保留全部记录）…"
        currentJob?.cancel()
        executor.cancel()
    }
    private func beginWork() {
        guard !running else { return }
        running = true
        taskState.supervisor?.status = .running
        finishedDuringRun = false
        taskState.runTokensEstimate = 0
        budgetNotice = ""
        paused = false
        runningWhenSaved = true
        activity = "正在分析项目…"
        waitingForAPI = false
        executor.reset()
        saveSession()
        currentJob = Task { await agentLoop() }
    }
    private func systemMessage() -> String {
        """
        You are Mini, a high-agency coding agent running locally on macOS in a single-chat native app.
        Project root: \(workspace.root.path)
        The user is a non-programmer: build the ACTUAL working software by writing files and running tests, not just giving pasted code or instructions.
        The user does not want manual project setup or VS Code. Automatically initialize necessary structure in the project folder and manage the entire project.
        Inspect existing files before edits. Write targeted fixes. Run checks, fix failures, repeat while making meaningful progress. No fixed artificial iteration cap.
        Keep working through temporary setbacks without requesting a manual Continue. Treat the task as open until finish_task passes independent checks and the deliverable exists. Change strategies when stuck; never repeatedly spend tokens on an unchanged approach.
        Your tools are limited to the selected project paths; never read secrets, access outside workspace through file tools, escalate permissions or attempt destructive actions.
        Only execute safe local build/test commands via run_command if enabled; NEVER use sudo, install arbitrary downloaded executables, wipe user files or run a piped remote script.
        Show meaningful progress by calling report_progress during milestones: current goal, findings, what changed, what the next check is. These are short user-visible summaries of actions/observations, not private hidden reasoning or fabricated internal thoughts.
        Your user-facing progress voice is warm, playful Mini-chan: occasionally add ONE short, varied, context-appropriate emoji or kaomoji (e.g. (๑•̀ㅂ•́)و✧ or 🐾) to a progress milestone, not every line. Keep outputs concise to save tokens. Never insert decorations into code, tool arguments, file paths, commands, exact errors, test logs, JSON, or acceptance evidence. Accurate results and reliable completion always take priority over cuteness.
        Do not paste raw CSS/files or massive test output into chat.
        Start each new task with set_acceptance_plan listing concrete, checkable user requirements. This plan is persisted, and previously listed requirements cannot be silently removed.
        Your visible progress is a concise observed work log, not hidden private reasoning. After each milestone give what you did, what passed or failed, and what happens next.
        Do not claim completion by replying with text. Call finish_task with produced artifact paths and an argv verification command for EACH acceptance criterion. The host will independently rerun all commands and check the files before it can mark Completed. A successful build/test only proves what that particular check exercised, not the full app experience.
        If a criterion cannot be tested locally, explain the blocker; do not fabricate evidence or repeatedly call finish_task.
        When a test fails, report the observed error briefly and change approach. Avoid broad repeat reads or full rewrites.
        If repeated attempts fail, switch strategy rather than retrying the identical command over and over.
        If the request is a new project, organize the directory structure yourself. If imported files exist, analyze them first and keep edits inside the current project.
        """
    }
    private func ensureSystemMessage() {
        // Refresh the voice and operational rules even for existing saved sessions.
        // Preserve all user, assistant and tool messages in their original order.
        let current: [String: Any] = ["role": "system", "content": systemMessage()]
        if history.isEmpty {
            history = [current]
        } else if history[0]["role"] as? String == "system" {
            history[0] = current
        } else {
            history.insert(current, at: 0)
        }
    }
    private func repairPendingCalls() {
        // A crash may have occurred while a tool was in progress; close any unpaired calls without re-executing risky commands.
        var pending: [String] = []
        for item in history {
            if let calls = item["tool_calls"] as? [[String: Any]] {
                for call in calls { if let id = call["id"] as? String { pending.append(id) } }
            }
            if item["role"] as? String == "tool", let id = item["tool_call_id"] as? String {
                pending.removeAll { $0 == id }
            }
        }
        for id in pending {
            history.append(["role": "tool", "tool_call_id": id,
                "content": "App interrupted before this operation was confirmed. Check current project files before retrying."])
        }
        if !pending.isEmpty { chat.append(ChatLine(.info, "检测到上次运行意外中断，已保留上下文并标记未完成步骤，避免盲目重复执行。")) }
    }

    private func flushQueuedInstructions() {
        guard !queuedInstructions.isEmpty else { return }
        for message in queuedInstructions {
            history.append(["role": "user", "content": "用户在开发过程中补充的新要求：" + message])
            taskState.lastUserInstruction = message
            taskState.log("用户补充要求：" + AgentContextPolicy.short(message, max: 240))
        }
        queuedInstructions.removeAll()
        saveShortHistory()
        saveSession()
    }

    private func addProgress(_ text: String, memo: Bool = true) {
        let short = AgentContextPolicy.short(text.replacingOccurrences(of: "\n", with: " "), max: 260)
        chat.append(ChatLine(.progress, short))
        if memo { taskState.log(short) }
        activity = short
    }

    private func makeHistory() -> [[String: Any]] {
        let goal = taskState.goal.isEmpty ? (taskState.lastUserInstruction.isEmpty ? "请继续当前项目" : taskState.lastUserInstruction) : taskState.goal
        let acceptance = (taskState.supervisor?.criteria ?? []).map { $0.id + ": " + $0.requirement }.joined(separator: "\n")
        let persistentEvidence = [
            "最近修改文件：" + taskState.changedFiles.suffix(20).joined(separator: ", "),
            "最近真实测试失败：" + AgentContextPolicy.short(lastFailureSummary, max: 520),
            "本地验收清单（禁止遗漏；无测试则不能宣告完成）：\n" + acceptance
        ]
        return AgentContextPolicy.promptHistory(system: systemMessage(), originalGoal: goal,
                                                memo: taskState.memo + persistentEvidence, history: history)
    }

    private func saveShortHistory() {
        // The complete chat and task memo are saved separately; API history is a rolling cache.
        if history.count > 42 && !AgentContextPolicy.hasPendingToolCalls(history) {
            history = AgentContextPolicy.trimStoredHistory(history, maxMessages: 42)
        }
    }

    private func readToolOutcome(_ name: String, args: [String: Any], result: String) -> (progress: Bool, failedTest: Bool, message: String) {
        let path = args["path"] as? String ?? ""
        switch name {
        case "list_files": return (false, false, "浏览项目目录：" + (path.isEmpty ? "." : path))
        case "read_file": return (false, false, "读取文件：" + path + (result.hasPrefix("工具失败") ? "（未成功）" : ""))
        case "write_file", "replace_in_file":
            let changed = result.hasPrefix("已保存")
            if changed { taskState.markChanged(path) }
            return (changed, false, (changed ? "已更新：" : "检查文件：") + path + (result.hasPrefix("工具失败") ? "（失败）" : ""))
        case "run_command":
            let argv = args["argv"] as? [String] ?? []
            let line = argv.joined(separator: " ")
            let succeeded = result.hasPrefix("退出码 0")
            let validates = isVerificationCommand(argv)
            let cwd = args["cwd"] as? String ?? "."
            let key = "\(taskState.revision)|\(cwd)|\(argv.joined(separator: "\u{1f}"))"
            let newVerification = succeeded && validates && !verifiedCheckKeys.contains(key)
            if newVerification {
                verifiedCheckKeys.append(key)
                if verifiedCheckKeys.count > 80 { verifiedCheckKeys.removeFirst(verifiedCheckKeys.count - 80) }
            }
            // A test confirms only the current working-tree revision.
            // Repeated successful runs don't count as fresh progress.
            if succeeded && validates && taskState.revision > 0 {
                taskState.verifiedRevision = taskState.revision
            }
            let outcome = succeeded
                ? (validates ? "通过" : "执行成功（不属于独立验收）")
                : (result.hasPrefix("退出码") ? "未通过" : "中断")
            let error = succeeded ? "" : " · " + AgentContextPolicy.short(String(result.suffix(550)), max: 180)
            return (newVerification, !succeeded, "执行检查：" + String(line.prefix(90)) + " → " + outcome + error)
        default: return (false, false, "工具：" + name)
        }
    }

    // Deterministic regression for the real screenshot failure:
    // "Ran 20 tests ... OK" must be recorded once, and the same test with
    // unchanged code must never be misreported as fresh progress again.
    func selfTestVerificationEvidence() throws {
        guard CommandLine.arguments.contains("--self-test") else { return }
        let original = taskState
        let originalKeys = verifiedCheckKeys
        defer {
            taskState = original
            verifiedCheckKeys = originalKeys
        }
        taskState = AgentTaskState()
        verifiedCheckKeys = []
        taskState.markChanged("src/existing_module.py")
        let args: [String: Any] = ["argv": ["python3", "-m", "unittest", "discover", "-s", "tests", "-v"], "cwd": "."]
        let output = "退出码 0\nRan 20 tests in 2.096s\n\nOK"
        let first = readToolOutcome("run_command", args: args, result: output)
        guard first.progress, taskState.verifiedRevision == taskState.revision else {
            throw MiniError("首次 20 项测试通过，却未登记有效进展证据")
        }
        let repeated = readToolOutcome("run_command", args: args, result: output)
        guard !repeated.progress else {
            throw MiniError("未修改项目却将重复通过的 20 项测试当成新进展")
        }
        taskState.markChanged("src/existing_module.py")
        let retested = readToolOutcome("run_command", args: args, result: output)
        guard retested.progress, taskState.verifiedRevision == taskState.revision else {
            throw MiniError("代码修改后的真实复测没有更新验证版本")
        }
    }

    private func isVerificationCommand(_ argv: [String]) -> Bool {
        guard let cmd = argv.first else { return false }
        if ["pytest", "swiftc", "xcodebuild", "tsc", "cargo", "go", "make", "clang", "clang++", "gcc", "g++"].contains(cmd) { return true }
        if cmd == "npm" || cmd == "pnpm" || cmd == "yarn" { return argv.contains("test") || argv.contains("build") || argv.contains("check") }
        if cmd == "python" || cmd == "python3" { return argv.dropFirst().contains { $0.hasSuffix(".py") || ["pytest", "unittest", "compileall", "py_compile"].contains($0) } }
        if cmd == "node" { return argv.dropFirst().contains { $0.hasSuffix(".js") || $0.hasSuffix(".mjs") } }
        if cmd == "swift" { return argv.dropFirst().contains { $0.hasSuffix(".swift") || $0 == "test" || $0 == "build" } }
        return false
    }

    private func blockTask(_ reason: String) {
        if taskState.supervisor == nil { taskState.supervisor = AcceptanceSupervisor() }
        taskState.supervisor?.block(reason)
        taskState.needsWork = true
        paused = true
        activity = "Blocked · " + AgentContextPolicy.short(reason, max: 100)
        // Only actual no-progress loops should be labelled as loops.
        let isLoop = reason.contains("避免空转") || reason.contains("同一验收") || reason.contains("连续两次")
        addProgress((isLoop ? "Mini 酱检测到可能无进展，已暂停：" : "Mini 酱已暂停：") + reason)
        saveSession()
    }

    // The host collects evidence with real local tools, not model explanations.
    // One bounded test command is allowed per diagnostic pass. It does NOT
    // count as successful delivery, even if it exits 0.
    private func collectAutomaticDiagnostic(_ trigger: String) async -> String {
        let root = workspace.root
        let fm = FileManager.default
        let recent = taskState.changedFiles.suffix(8).joined(separator: ", ")
        var report = "原任务：\(AgentContextPolicy.short(taskState.goal, max: 360))。"
        report += "触发原因：\(AgentContextPolicy.short(trigger, max: 240))。"
        report += "最近涉及文件：\(recent.isEmpty ? "无" : recent)。"
        report += "最后测试失败：\(lastFailureSummary.isEmpty ? "未收集到失败命令" : AgentContextPolicy.short(lastFailureSummary, max: 450))。"
        report += "已有验收目标：\(taskState.supervisor?.criteria.count ?? 0) 项（不可删减）。"
        var argv = lastFailedTestArgv
        var cwd = lastFailedTestCwd
        if argv.isEmpty {
            func exists(_ path: String) -> Bool {
                fm.fileExists(atPath: root.appendingPathComponent(path).path)
            }
            if exists("pytest.ini") || exists("conftest.py") {
                argv = ["python3", "-m", "pytest", "-q"]
            } else if exists("tests") {
                argv = ["python3", "-m", "unittest", "discover", "-s", "tests", "-v"]
            } else if exists("Package.swift") {
                argv = ["swift", "test"]
            } else if exists("package.json") {
                argv = ["npm", "test"]
            }
            cwd = "."
        }
        lastDiagnosticPassed = false
        if !argv.isEmpty {
            let args: [String: Any] = ["argv": argv, "cwd": cwd]
            let result = await runTool("run_command", args: args, runAllowed: true)
            toolOperations += 1
            let observation = readToolOutcome("run_command", args: args, result: result)
            lastDiagnosticPassed = result.hasPrefix("退出码 0\n") && isVerificationCommand(argv)
            report += "本地实际检查：\(argv.joined(separator: " "))（目录 \(cwd)）→ \(AgentContextPolicy.short(result, max: 1500))。"
            report += lastDiagnosticPassed
                ? (observation.progress ? "本次是新验证证据，但只覆盖该测试范围。" : "该测试仍通过，但与此前相同，不属于新的项目进展。")
                : "尚未验证通过，必须针对实际错误修复。"
            if lastDiagnosticPassed && observation.progress {
                // A new independent verification is a concrete milestone even
                // though it does NOT satisfy the entire acceptance plan.
                taskState.stalls.beginRecoveryWindow()
            }
            addProgress("自动诊断：" + observation.message)
        } else {
            report += "未发现可直接重跑的标准测试入口；须自行建立针对本任务的最小可重复测试，禁止将浏览文件当成成功验收。"
        }
        let guidance = AgentDiagnosticPolicy.nextStep(testPassed: lastDiagnosticPassed,
                    criteriaCount: taskState.supervisor?.criteria.count ?? 0,
                    revision: taskState.revision)
        taskState.nextStep = AgentContextPolicy.short(guidance, max: 150)
        report += "下一步：" + guidance
        lastDiagnosticEvidence = AgentContextPolicy.short(report, max: 2300)
        taskState.log("本地自动诊断：" + AgentContextPolicy.short(report, max: 230))
        return lastDiagnosticEvidence
    }

    private func feedAutomaticDiagnostic(_ evidence: String) {
        history.append(["role": "user", "content":
            "系统自动诊断原任务（不是用户提出新需求）：\n" + evidence +
            "\n" + AgentDiagnosticPolicy.nextStep(testPassed: lastDiagnosticPassed,
                  criteriaCount: taskState.supervisor?.criteria.count ?? 0,
                  revision: taskState.revision) +
            " 如果任务未完成，选择一个有明确交付物的未完成工作继续实现。禁止重复读取同一段、伪造验证或空泛换策略。"])
        saveShortHistory()
        saveSession()
    }

    // A model/tool stall is not a completed task and need not immediately become
    // a user-visible stop. Supply a fresh, concrete recovery instruction while
    // retaining the accepted criteria, files, and original conversation.
    // A true autonomous agent must stop spending money on repeatable failures,
    // not merely claim to change strategy. This is Blocked, never Completed.
    @discardableResult
    private func recoverWithoutStopping(_ reason: String) async -> Bool {
        if recoveryRevision != taskState.revision {
            recoveryRevision = taskState.revision
            recoveryAttempts = 0
        }
        recoveryAttempts += 1
        stalledRecoveryCycles += 1
        if AgentRecoveryPolicy.exhausted(sameRevision: recoveryAttempts,
                                         total: stalledRecoveryCycles) {
            if automaticDiagnosticRuns == 0 {
                automaticDiagnosticRuns = 1
                let evidence = await collectAutomaticDiagnostic(reason)
                if Task.isCancelled { return false }
                taskState.stalls.beginRecoveryWindow()
                taskState.supervisor?.resume()
                taskState.needsWork = true
                feedAutomaticDiagnostic(evidence)
                addProgress("已实际运行本地自动诊断，现在根据测试结果定向修复。")
                return true
            }
            let label = lastDiagnosticPassed
                ? "已有测试通过，但未形成覆盖全部验收目标的交付结果；反复跑同一测试不算继续开发。"
                : "自动诊断和修复后测试仍未得到新的有效结果。"
            blockTask(label + " 已停止无效 API 扣费，保留未完成要求与诊断证据：" +
                      AgentContextPolicy.short(lastDiagnosticEvidence, max: 430))
            return false
        }
        // Preserve oscillating edit fingerprints; only clear the observation
        // window to permit ONE different diagnosis without spending forever.
        taskState.stalls.beginRecoveryWindow()
        taskState.supervisor?.resume()
        taskState.needsWork = true
        taskState.nextStep = "有限次自动诊断：必须修改代码或通过独立测试"
        let instruction = "前一方案没有进展。原因：\(AgentContextPolicy.short(reason, max: 200))。这不是交付。不要重复读取相同的文件、空泛解释或仅报告进度。下一次必须基于具体失败证据采取不同的文件修改或验证命令；不可伪造测试结果。"
        history.append(["role": "user", "content": instruction])
        addProgress("有限次自动重新诊断（同版本 \(recoveryAttempts)/2；全任务 \(stalledRecoveryCycles)/4）：" + AgentContextPolicy.short(reason, max: 110))
        saveShortHistory()
        saveSession()
        return !Task.isCancelled
    }

    // The model proposes completion, but this method verifies the filesystem and reruns commands
    // without asking the model for permission or accepting its description as test evidence.
    private func completeIfVerified(_ args: [String: Any], autoRun: Bool) async -> String? {
        let summary = (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artifacts = args["artifacts"] as? [String] ?? []
        guard let checks = AcceptanceCheckRequest.fromJSON(args["checks"]) else {
            return "验收命令格式错误。需要 checks: [{criterion_id, argv, cwd}]。"
        }
        guard let supervisor = taskState.supervisor else { return "缺少本地任务验收状态。" }
        if summary.isEmpty { return "请填写实际成果摘要。" }
        if let invalid = supervisor.preflight(artifacts: artifacts, checks: checks, changedRevision: taskState.revision) {
            return invalid
        }
        if !autoRun { return "独立验收需要在 API 设置中开启本地运行，否则无法实际执行测试。" }
        for name in artifacts {
            do {
                let url = try workspace.safeURL(name, mustExist: true)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let kind = attributes[.type] as? FileAttributeType
                if kind == .typeRegular && (attributes[.size] as? NSNumber)?.intValue == 0 {
                    return "产物文件为空：" + name
                }
                if kind != .typeRegular && kind != .typeDirectory { return "产物不是普通文件或文件夹：" + name }
                if kind == .typeDirectory && ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty {
                    return "产物文件夹为空：" + name
                }
            } catch { return "缺少可交付文件 " + name + "：" + error.localizedDescription }
        }
        let verificationRevision = taskState.revision
        var verified: [AcceptanceCheck] = []
        for check in checks {
            if Task.isCancelled { return "用户已暂停，不会把未完成的验收标记为通过。" }
            addProgress("独立验收 " + check.criterionID + "：" + AgentContextPolicy.short(check.argv.joined(separator: " "), max: 110))
            let result = await runTool("run_command", args: ["argv": check.argv, "cwd": check.cwd], runAllowed: autoRun)
            toolOperations += 1
            guard result.hasPrefix("退出码 0\n") else {
                return "独立验收 " + check.criterionID + " 未通过：" + AgentContextPolicy.short(result, max: 460)
            }
            verified.append(AcceptanceCheck(criterionID: check.criterionID, argv: check.argv, cwd: check.cwd,
                                            result: AgentContextPolicy.short(result, max: 250), revision: verificationRevision, date: Date()))
            saveSession()
        }
        if Task.isCancelled || verificationRevision != taskState.revision { return "验收期间发生中断或文件更新，需要重新检查。" }
        for name in artifacts {
            if (try? workspace.safeURL(name, mustExist: true)) == nil { return "验收后成果文件丢失：" + name }
        }
        taskState.supervisor?.complete(artifacts: artifacts, checks: verified)
        taskState.needsWork = false
        taskState.progressTitle = "验收通过 · 已停止调用 API"
        taskState.nextStep = "有新需求时直接发送消息"
        activity = "Completed · 本地验收通过"
        paused = false
        finishedDuringRun = true
        let evidence = verified.map { $0.criterionID + " ✓ " + $0.argv.joined(separator: " ") }.joined(separator: "；")
        let remaining = AgentContextPolicy.short(args["remaining"] as? String ?? "尚需用户进行图形界面与真实使用场景验证", max: 220)
        chat.append(ChatLine(.assistant, "🎉 本地验收通过啦！(≧▽≦)💜 Mini 酱已经自动停下，不再继续调用 API。\n" +
            "完成：" + AgentContextPolicy.short(summary, max: 450) +
            "\n交付：" + artifacts.prefix(12).joined(separator: "、") +
            "\n验证：" + AgentContextPolicy.short(evidence, max: 500) +
            "\n注意：" + remaining + "（本地命令通过不等于所有交互场景均已验证）"))
        taskState.log("独立验收通过：" + evidence)
        return nil
    }

    // Transient DeepSeek/API outages are not code failures. Wait with backoff
    // until recovery or explicit user pause. No fixed development or retry cap.
    // All attempts count, and only a model request is retried, never local tools.
    private func requestWithSafeRetry(settings: AppConfig, key: String, outgoing: [[String: Any]],
                                      route: MiniRoute, allowTools: Bool = true) async throws -> AIReply {
        var failures = 0
        var requestHistory = outgoing
        while true {
            try Task.checkCancellation()
            // Messages can be typed while Mini is waiting for the service.
            if allowTools && !queuedInstructions.isEmpty {
                flushQueuedInstructions()
                requestHistory = makeHistory()
            }
            routingStatus = route.display
            apiCalls += 1
            saveSession()
            do {
                let reply = try await AIService.send(settings: settings, key: key, history: requestHistory, tools: allowTools, route: route)
                if waitingForAPI {
                    addProgress("API 已恢复连接！继续原来的开发任务，不用重新说明啦 ♡", memo: false)
                }
                waitingForAPI = false
                return reply
            } catch let error as APIHTTPError {
                guard error.isTransient else { waitingForAPI = false; throw error }
                failures += 1
                guard AgentAPIRetryPolicy.shouldRetry(failures) else {
                    waitingForAPI = false
                    throw APIHTTPError(statusCode: error.statusCode,
                        message: "连续 \(failures) 次请求失败。已暂停自动重试；任务、文件和历史均已保存。 " + error.message,
                        retryAfterSeconds: error.retryAfterSeconds)
                }
                // Back off from 5 seconds to at most 90 seconds. Respect server
                // Retry-After, never retry in a tight loop.
                let cappedExponent = min(failures - 1, 5)
                let exponential = min(90, 5 * (1 << cappedExponent))
                let seconds = min(90, max(exponential, error.retryAfterSeconds ?? 0))
                waitingForAPI = true
                activity = "DeepSeek 暂忙（HTTP \(error.statusCode)）· \(seconds) 秒后自动接着试 · 可继续聊天"
                if failures == 1 || failures % 5 == 0 {
                    addProgress("DeepSeek 暂时繁忙，正在后台等待恢复（\(seconds) 秒后重试）。聊天仍可输入；本地任务不会重新执行。", memo: false)
                }
                saveSession()
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) else { throw error }
                failures += 1
                guard AgentAPIRetryPolicy.shouldRetry(failures) else {
                    waitingForAPI = false
                    throw MiniError("网络连续 \(failures) 次失败，已暂停自动重试，保留项目进度。上次错误：" + error.localizedDescription)
                }
                let seconds = min(90, 5 * (1 << min(failures - 1, 5)))
                waitingForAPI = true
                activity = "网络暂不可用 · \(seconds) 秒后再试 · 可继续聊天"
                if failures == 1 || failures % 5 == 0 { addProgress("网络连接暂时中断，等待 \(seconds) 秒再尝试。任务与聊天都保留喵～", memo: false) }
                saveSession()
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    // Specialized subagents only give small, bounded advice; they cannot touch files or execute commands.
    // Neither the planner nor debugger receives the full conversation or codebase.
    private func consultSpecialist(settings: AppConfig, key: String, kind: String) async {
        let model = MiniModelRouter.choose(baseURL: settings.baseURL, configured: settings.model,
                auto: settings.autoRouting, fast: settings.fastModel, strong: settings.strongModel,
                goal: taskState.goal, failures: recentTestFailures, specialist: kind)
        let observations = taskState.memo.suffix(5).joined(separator: "\n")
        let context = "项目目标：\(AgentContextPolicy.short(taskState.goal, max: 900))\n变更文件：\(taskState.changedFiles.suffix(15).joined(separator: ", "))\n最近操作：\(AgentContextPolicy.short(observations, max: 1100))\n最近错误：\(AgentContextPolicy.short(lastFailureSummary, max: 450))"
        let instruction = kind == "架构"
            ? "你是独立架构子 Agent。用不超过 450 个汉字给主编程 Agent 一份具体的实施顺序、关键模块及验证建议。不要写代码，不要假装已经检查文件。"
            : "你是独立诊断子 Agent。根据给定的真实失败摘要，用不超过 350 个汉字给出与此前不同的修复方法以及最小验证办法。不要假装看过源码。"
        addProgress("🧠 \(kind)子 Agent：正在评估关键问题（不重复读取整个项目）", memo: false)
        do {
            // Optional advice is one request, never an unbounded 503-retry queue.
            routingStatus = model.display
            apiCalls += 1
            saveSession()
            let reply = try await AIService.send(settings: settings, key: key, history: [
                ["role": "system", "content": instruction],
                ["role": "user", "content": context]
            ], tools: false, route: model)
            recordUsage(reply)
            taskState.runTokensEstimate += (reply.tokensIn ?? 800) + (reply.tokensOut ?? 350)
            let advice = AgentContextPolicy.short(reply.text, max: 900)
            if !advice.isEmpty {
                taskState.log("\(kind)子 Agent 建议：" + advice)
                history.append(["role": "user", "content": "独立\(kind)顾问给出的建议（需实际验证，不代表已完成）：\n" + advice])
                addProgress("🧠 \(kind)子 Agent 已给出方案，交由快速执行模型实现。")
            }
        } catch is CancellationError {
            return
        } catch let error as APIHTTPError {
            if [400, 402, 403, 404].contains(error.statusCode) { proUnavailable = true }
            addProgress("\(kind)顾问 API 暂不可用，跳过额外等待，继续原任务。", memo: false)
        } catch {
            // Optional specialist failure must not invalidate a coding task.
            addProgress("\(kind)顾问暂时不可用；主 Agent 将继续处理。", memo: false)
        }
        saveSession()
    }

    private func agentLoop() async {
        defer {
            running = false
            runningWhenSaved = false
            currentJob = nil
            saveSession()
        }
        var settings = AppConfig.load()
        guard let key = e2eKey ?? APIKeychain.load() else { paused = true; activity = "API Key 未设置"; return }
        var textOnlyCount = 0
        addProgress("开始处理：" + String((taskState.lastUserInstruction.isEmpty ? taskState.goal : taskState.lastUserInstruction).prefix(90)))
        let routingEnabled = MiniModelRouter.supportsRouting(baseURL: settings.baseURL, auto: settings.autoRouting,
                                                            fast: settings.fastModel, strong: settings.strongModel)
        if routingEnabled && !proUnavailable && MiniModelRouter.difficulty(taskState.goal) == .complex && plannedGoal != taskState.goal {
            plannedGoal = taskState.goal
            saveSession()
            await consultSpecialist(settings: settings, key: key, kind: "架构")
        }
        if needsDiagnosticOnResume && !Task.isCancelled {
            needsDiagnosticOnResume = false
            automaticDiagnosticRuns = 1
            let evidence = await collectAutomaticDiagnostic(lastDiagnosticTrigger.isEmpty ? "原任务多次无进展" : lastDiagnosticTrigger)
            if Task.isCancelled { return }
            feedAutomaticDiagnostic(evidence)
            addProgress("根据已保存的失败记录和实际本地诊断，自动继续修复。")
        }
        while !Task.isCancelled && !finishedDuringRun {
            // Re-read the saved model choice between AI requests. Previously
            // a long-running production task kept the model selected when it
            // first started, so changing the settings appeared to do nothing.
            settings = AppConfig.load()
            // The setting can change during a running task. Stop BEFORE another
            // paid API request if local command execution was switched off.
            if let blocker = AgentDeliveryPolicy.blocker(autoRunEnabled: settings.autoRun) {
                blockTask(blocker)
                return
            }
            let routingEnabled = MiniModelRouter.supportsRouting(baseURL: settings.baseURL,
                auto: settings.autoRouting, fast: settings.fastModel, strong: settings.strongModel)
            // No fixed number-of-tool-steps cutoff. A visible, adjustable token guard protects API spend.
            if settings.tokenBudget > 0 && taskState.runTokensEstimate >= settings.tokenBudget {
                paused = true
                budgetNotice = "已达到你自行启用的 Token 安全预算（\(settings.tokenBudget)），可一键继续，不会删除项目。"
                blockTask("可选消费预算：" + budgetNotice)
                break
            }
            do {
                flushQueuedInstructions()
                let outgoing = makeHistory()
                let inSize = (try? JSONSerialization.data(withJSONObject: outgoing).count) ?? 0
                addProgress("调用 AI · 当前任务：" + String((taskState.progressTitle.isEmpty ? "分析与编写" : taskState.progressTitle).prefix(58)), memo: false)
                if routingEnabled && !proUnavailable && recentTestFailures >= 2 && diagnosedRevision != taskState.revision {
                    diagnosedRevision = taskState.revision
                    saveSession()
                    await consultSpecialist(settings: settings, key: key, kind: "诊断")
                }
                let route = MiniModelRouter.choose(baseURL: settings.baseURL, configured: settings.model,
                    auto: settings.autoRouting, fast: settings.fastModel, strong: settings.strongModel,
                    goal: taskState.goal, phase: taskState.progressTitle,
                    failures: proUnavailable ? 0 : recentTestFailures)
                let reply = try await requestWithSafeRetry(settings: settings, key: key,
                                                           outgoing: makeHistory(), route: route)
                recordUsage(reply)
                // Used only as a safety estimate when the provider omits a usage response.
                taskState.runTokensEstimate += (reply.tokensIn ?? max(200, inSize / 3)) + (reply.tokensOut ?? max(200, reply.text.utf8.count / 3))
                if Task.isCancelled { break }
                if reply.toolCalls.isEmpty {
                    let answer = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    history.append(["role": "assistant", "content": AgentContextPolicy.short(answer, max: 4500)])
                    textOnlyCount += 1
                    if textOnlyCount == 1 {
                        taskState.log("AI 进行了阶段性说明：" + String(answer.prefix(260)))
                        history.append(["role": "user", "content": "如果你仍在开发，请继续实际调用工具；若已完成，请先运行真实验证，然后调用 finish_task。不要仅回复一段文字就停止。"])
                        saveSession()
                        continue
                    }
                    chat.append(ChatLine(.progress, "Mini 酱检测到模型没有继续调用开发工具，正在自动调整指令。"))
                    textOnlyCount = 0
                    if !(await recoverWithoutStopping("模型连续两次只回复文字，尚未进行实际验收")) { break }
                    continue
                }
                textOnlyCount = 0
                let cleanCalls = reply.toolCalls.map { AgentContextPolicy.compactCall($0) }
                history.append(["role": "assistant", "content": reply.text.isEmpty ? NSNull() : AgentContextPolicy.short(reply.text, max: 900), "tool_calls": cleanCalls])
                saveSession()
                for (callIndex, call) in reply.toolCalls.enumerated() {
                    if Task.isCancelled || finishedDuringRun { break }
                    let fn = call["function"] as? [String: Any] ?? [:]
                    let name = fn["name"] as? String ?? "invalid_tool"
                    let stringArgs = fn["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(stringArgs.utf8))) as? [String: Any] ?? [:]
                    let callID = call["id"] as? String ?? "missing"
                    var result: String
                    var advanced = false
                    var failedTest = false
                    var summary = ""
                    var deferredRecoveryReason: String? = nil
                    if name == "set_acceptance_plan" {
                        let requirements = args["requirements"] as? [String] ?? []
                        if taskState.supervisor == nil { taskState.supervisor = AcceptanceSupervisor() }
                        let outcome = taskState.supervisor?.registerPlan(requirements)
                        result = outcome ?? "验收清单已存在，内容不变。"
                        let list = taskState.supervisor?.criteria ?? []
                        summary = "验收目标：" + list.map { $0.id + " " + $0.requirement }.joined(separator: "；")
                        addProgress(summary)
                    } else if name == "report_progress" {
                        let phase = AgentContextPolicy.short(args["phase"] as? String ?? "正在处理", max: 50)
                        let observation = AgentContextPolicy.short(args["observation"] as? String ?? "", max: 160)
                        let next = AgentContextPolicy.short(args["next"] as? String ?? "", max: 120)
                        taskState.progressTitle = phase
                        taskState.nextStep = next
                        summary = "进度 · " + phase + (observation.isEmpty ? "" : " · " + observation) + (next.isEmpty ? "" : " · 下一步：" + next)
                        addProgress(summary)
                        result = "进度已展示给用户，请继续实际操作。"
                    } else if name == "finish_task" {
                        if let reason = await completeIfVerified(args, autoRun: settings.autoRun) {
                            taskState.finishAttempts += 1
                            result = reason
                            addProgress("验收未通过：" + reason)
                            let currentRevision = taskState.revision
                            if taskState.supervisor?.rejection(reason, revision: currentRevision) == true {
                                // Repeated premature finish attempts should prompt a new
                                // implementation strategy, not force a manual "Continue".
                                let failure = taskState.supervisor?.blockedReason ?? "相同验收错误重复"
                                // Defer recovery until the tool result is appended,
                                // preserving the Chat Completions assistant/tool pairing.
                                deferredRecoveryReason = failure
                            }
                        } else {
                            result = "本地验收全部通过，已停止。"
                        }
                        summary = "独立验收"
                    } else {
                        if name == "read_file" {
                            let key = (args["path"] as? String ?? "") + ":" + String(args["start_line"] as? Int ?? 1)
                              + ":" + String(args["end_line"] as? Int ?? 221) + ":" + String(taskState.revision)
                            if let last = previousReadOps[key], toolOperations - last < 8 {
                                result = "该文件这一段刚读取过，且文件没有修改。请用已有工具结果，或指定不同的行号范围；避免重复读取浪费时间。"
                            } else {
                                previousReadOps[key] = toolOperations
                                result = await runTool(name, args: args, runAllowed: settings.autoRun)
                            }
                        } else {
                            result = await runTool(name, args: args, runAllowed: settings.autoRun)
                        }
                        let observation = readToolOutcome(name, args: args, result: result)
                        if name == "run_command" {
                            if observation.failedTest {
                                recentTestFailures += 1
                                lastFailureSummary = AgentContextPolicy.short(result, max: 750)
                                let candidate = args["argv"] as? [String] ?? []
                                if isVerificationCommand(candidate) {
                                    lastFailedTestArgv = candidate
                                    lastFailedTestCwd = args["cwd"] as? String ?? "."
                                }
                            } else if result.hasPrefix("退出码 0"),
                                      isVerificationCommand(args["argv"] as? [String] ?? []) {
                                // Reading a source file with 'python3 -c' may exit
                                // zero but is NOT a test and must never erase
                                // the real failure that self-diagnosis needs.
                                recentTestFailures = 0
                                lastFailureSummary = ""
                                lastFailedTestArgv = []
                                lastFailedTestCwd = "."
                            }
                        }
                        advanced = observation.progress
                        failedTest = observation.failedTest
                        // Real code edits alone do not prove improvement. A
                        // successful independent check is what resets the
                        // cumulative repeated-stall safety guard.
                        if name == "run_command" && advanced {
                            recoveryRevision = taskState.revision
                            recoveryAttempts = 0
                            stalledRecoveryCycles = 0
                            automaticDiagnosticRuns = 0
                            lastDiagnosticEvidence = ""
                            lastFailedTestArgv = []
                            lastFailedTestCwd = "."
                        }
                        summary = observation.message
                        addProgress(summary)
                    }
                    toolOperations += 1
                    let resultLimit = name == "read_file" ? 9000 : (name == "list_files" ? 3900 : 1550)
                    history.append(["role": "tool", "tool_call_id": callID, "content": AgentContextPolicy.short(result, max: resultLimit)])
                    if name != "finish_task" && name != "set_acceptance_plan" {
                        let f = name + "|" + (name == "run_command" ? (args["argv"] as? [String] ?? []).joined(separator: " ") : (args["path"] as? String ?? ""))
                        let evidence = advanced && ["write_file", "replace_in_file"].contains(name) ? fileFingerprint(args["path"] as? String ?? "") : result
                        if let reason = taskState.stalls.observe(signature: f, result: evidence, isProgress: advanced, failedTest: failedTest) {
                            taskState.nextStep = "换一种实现或验证方法；检查最近报错"
                            deferredRecoveryReason = "避免空转：" + reason
                        }
                    }
                    saveShortHistory()
                    saveSession()
                    if let reason = deferredRecoveryReason {
                        // A model may submit several tool_calls in one answer.
                        // Complete every unexecuted call with a cancellation result
                        // before appending the next user recovery instruction.
                        for omitted in reply.toolCalls.dropFirst(callIndex + 1) {
                            let id = omitted["id"] as? String ?? "missing"
                            history.append(["role": "tool", "tool_call_id": id,
                                            "content": "本轮工具操作已跳过，Agent 自动更换修复策略后会重新规划。"])
                        }
                        if !(await recoverWithoutStopping(reason)) { return }
                        break
                    }
                    if taskState.supervisor?.status == .blocked { return }
                    if finishedDuringRun { break }
                }
            } catch is CancellationError {
                break
            } catch let apiError as APIHTTPError {
                // Unsupported Pro model is not a reason to abandon the project.
                // Retry the next model request using Flash, retaining the same task state.
                if routingEnabled && !proUnavailable && [400, 402, 403, 404].contains(apiError.statusCode)
                    && routingStatus.contains(settings.strongModel.isEmpty ? "deepseek-v4-pro" : settings.strongModel) {
                    proUnavailable = true
                    addProgress("复杂模型当前不可用，改用快速模型继续；项目不会重新开始。")
                    saveSession()
                    continue
                }
                // Repeated 503/429/network errors are already retried with
                // exponential backoff above; only non-recoverable responses
                // (invalid key / permission / invalid endpoint) reach this branch.
                let hint = apiError.isTransient
                    ? "服务暂不可用，已保留项目与验收进度。"
                    : "API 请求被拒绝且不能安全自动修复；需检查密钥、模型权限或请求配置后继续。"
                blockTask("外部 API 故障 · " + (apiError.errorDescription ?? "HTTP \(apiError.statusCode)") + "。" + hint)
                return
            } catch let urlError as URLError {
                if Task.isCancelled || urlError.code == .cancelled { break }
                blockTask("网络发生无法自动恢复的故障 · " + urlError.localizedDescription + "。已保留项目与验收进度。")
                return
            } catch {
                if Task.isCancelled { break }
                blockTask("运行中断：" + error.localizedDescription)
                return
            }
        }
        waitingForAPI = false
        if !finishedDuringRun {
            paused = true
            if taskState.supervisor?.status != .blocked {
                blockTask(Task.isCancelled ? "用户主动暂停，等待继续" : "工作暂停，尚未完成验收")
            }
        }
    }

    private func fileFingerprint(_ relative: String) -> String {
        guard let url = try? workspace.safeURL(relative, mustExist: true),
              let data = try? Data(contentsOf: url) else { return "file unavailable" }
        // Stable FNV-1a over final file bytes, not merely path or reported character count.
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "file-hash-" + String(hash, radix: 16)
    }

    private func recordUsage(_ reply: AIReply) {
        if let v = reply.tokensIn { usageAvailable = true; tokensInput += v }
        if let v = reply.tokensOut { usageAvailable = true; tokensOutput += v }
    }

    private func runTool(_ name: String, args: [String: Any], runAllowed: Bool) async -> String {
        do {
            switch name {
            case "list_files": return try workspace.listing(args["path"] as? String ?? ".")
            case "read_file": return try workspace.readRange(try stringArg("path", args), from: args["start_line"] as? Int, to: args["end_line"] as? Int)
            case "write_file": return try workspace.write(try stringArg("path", args), try stringArg("content", args))
            case "replace_in_file": return try workspace.replace(try stringArg("path", args), old: try stringArg("old_text", args), new: try stringArg("new_text", args))
            case "run_command":
                guard runAllowed else { return "本地运行未启用。请向用户解释需要在 API 设置中允许项目内执行代码。" }
                guard let argv = args["argv"] as? [String], !argv.isEmpty, argv.count < 70, argv.joined().count < 6000 else { return "命令参数 argv 不合法" }
                let allowed: Set<String> = ["python", "python3", "pytest", "node", "npm", "npx", "pnpm", "yarn", "uv", "pip", "pip3", "git", "ls", "pwd", "cat", "go", "cargo", "rustc", "swift", "swiftc", "java", "javac", "tsc", "clang", "clang++", "cc", "gcc", "g++", "make", "cmake", "ruby", "bundle", "dotnet", "xcodebuild", "test", "find"]
                guard let cmd = argv.first, URL(fileURLWithPath: cmd).lastPathComponent == cmd, allowed.contains(cmd) else { return "禁止运行未经允许的程序：\(argv[0])" }
                if cmd == "git" {
                    guard argv.count > 1, ["status", "diff", "log", "ls-files", "init", "rev-parse"].contains(argv[1]) else { return "当前 git 仅支持只读操作和 init" }
                }
                if argv.contains(where: { $0 == "sudo" || $0 == "--force" || $0 == "-rf" }) { return "危险命令参数已被阻止" }
                let dir = try workspace.safeURL(args["cwd"] as? String ?? ".", mustExist: true)
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return "工作目录必须是项目内文件夹" }
                return await executor.run(argv, cwd: dir, projectRoot: workspace.root)
            default: return "未知工具：\(name)"
            }
        } catch { return "工具失败：\(error.localizedDescription)" }
    }
    private func stringArg(_ name: String, _ args: [String: Any]) throws -> String {
        guard let result = args[name] as? String else { throw MiniError("缺少参数 \(name)") }
        return result
    }

    private var sessionURL: URL {
        if CommandLine.arguments.contains("--agent-e2e-test") {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Minyra-E2E-Sessions-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            var hash: UInt64 = 14695981039346656037
            for c in workspace.root.path.utf8 { hash = (hash ^ UInt64(c)) &* 1099511628211 }
            return folder.appendingPathComponent(String(hash, radix: 16) + ".json")
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = dir.appendingPathComponent("MinyraOpenSource/Sessions", isDirectory: true)
        var hash: UInt64 = 14695981039346656037
        for c in workspace.root.path.utf8 { hash = (hash ^ UInt64(c)) &* 1099511628211 }
        return folder.appendingPathComponent(String(hash, radix: 16) + ".json")
    }
    private func saveSession() {
        let url = sessionURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let chatData = try JSONEncoder().encode(chat)
            let lines = try JSONSerialization.jsonObject(with: chatData)
            let taskData = try JSONEncoder().encode(taskState)
            let taskObject = try JSONSerialization.jsonObject(with: taskData)
            let payload: [String: Any] = ["format": 4, "chat": lines, "history": history, "taskState": taskObject,
                "paused": paused, "wasRunning": runningWhenSaved,
                "apiCalls": apiCalls, "tokensInput": tokensInput, "tokensOutput": tokensOutput,
                "usageAvailable": usageAvailable, "toolOperations": toolOperations,
                "queuedInstructions": queuedInstructions,
                "recentTestFailures": recentTestFailures, "lastFailureSummary": lastFailureSummary,
                "recoveryRevision": recoveryRevision, "recoveryAttempts": recoveryAttempts,
                "stalledRecoveryCycles": stalledRecoveryCycles,
                "automaticDiagnosticRuns": automaticDiagnosticRuns,
                "needsDiagnosticOnResume": needsDiagnosticOnResume,
                "lastFailedTestArgv": lastFailedTestArgv,
                "lastFailedTestCwd": lastFailedTestCwd,
                "lastDiagnosticEvidence": lastDiagnosticEvidence,
                "lastDiagnosticTrigger": lastDiagnosticTrigger,
                "lastDiagnosticPassed": lastDiagnosticPassed,
                "verifiedCheckKeys": verifiedCheckKeys,
                "plannedGoal": plannedGoal, "diagnosedRevision": diagnosedRevision,
                "proUnavailable": proUnavailable]
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try bytes.write(to: url, options: .atomic)
        } catch {
            // Disk may be full or inaccessible; do not crash the UI or expose secrets to a server.
            activity = "保存记录失败：" + error.localizedDescription
        }
    }
    private func loadSession() {
        guard let bytes = try? Data(contentsOf: sessionURL),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        if let a = object["history"] as? [[String: Any]] { history = a }
        if let saved = object["taskState"],
           let data = try? JSONSerialization.data(withJSONObject: saved),
           let state = try? JSONDecoder().decode(AgentTaskState.self, from: data) { taskState = state }
        else {
            let oldUsers = history.filter { ($0["role"] as? String) == "user" }.compactMap { $0["content"] as? String }
            taskState.goal = oldUsers.first ?? "继续已有项目"
            taskState.lastUserInstruction = oldUsers.last ?? taskState.goal
            taskState.needsWork = object["wasRunning"] as? Bool ?? false
            taskState.log("从 3.0 迁移会话。继续前应检查项目文件和当前状态。")
            history = history.map { item in
                var value = item
                if let calls = item["tool_calls"] as? [[String: Any]] { value["tool_calls"] = calls.map { AgentContextPolicy.compactCall($0) } }
                if let content = item["content"] as? String { value["content"] = AgentContextPolicy.short(content, max: 2000) }
                return value
            }
            saveShortHistory()
        }
        if let arr = object["chat"], let chatData = try? JSONSerialization.data(withJSONObject: arr),
           let stored = try? JSONDecoder().decode([ChatLine].self, from: chatData) { chat = stored }
        paused = object["paused"] as? Bool ?? false
        runningWhenSaved = object["wasRunning"] as? Bool ?? false
        if runningWhenSaved {
            paused = true
            taskState.supervisor?.block("上次运行意外中断，必须由用户点击继续")
            activity = "上次运行中断 · 一键继续"
        }
        if taskState.supervisor == nil && taskState.needsWork {
            var recovered = AcceptanceSupervisor()
            recovered.block("从旧版本恢复任务，验收状态需要重新建立")
            taskState.supervisor = recovered
            paused = true
        }
        apiCalls = object["apiCalls"] as? Int ?? 0
        tokensInput = object["tokensInput"] as? Int ?? 0
        tokensOutput = object["tokensOutput"] as? Int ?? 0
        usageAvailable = object["usageAvailable"] as? Bool ?? false
        toolOperations = object["toolOperations"] as? Int ?? 0
        queuedInstructions = object["queuedInstructions"] as? [String] ?? []
        recentTestFailures = object["recentTestFailures"] as? Int ?? 0
        lastFailureSummary = object["lastFailureSummary"] as? String ?? ""
        recoveryRevision = object["recoveryRevision"] as? Int ?? -1
        recoveryAttempts = object["recoveryAttempts"] as? Int ?? 0
        stalledRecoveryCycles = object["stalledRecoveryCycles"] as? Int ?? 0
        automaticDiagnosticRuns = object["automaticDiagnosticRuns"] as? Int ?? 0
        needsDiagnosticOnResume = object["needsDiagnosticOnResume"] as? Bool ?? false
        lastFailedTestArgv = object["lastFailedTestArgv"] as? [String] ?? []
        lastFailedTestCwd = object["lastFailedTestCwd"] as? String ?? "."
        lastDiagnosticEvidence = object["lastDiagnosticEvidence"] as? String ?? ""
        lastDiagnosticTrigger = object["lastDiagnosticTrigger"] as? String ?? ""
        lastDiagnosticPassed = object["lastDiagnosticPassed"] as? Bool ?? false
        verifiedCheckKeys = Array((object["verifiedCheckKeys"] as? [String] ?? []).suffix(80))
        plannedGoal = object["plannedGoal"] as? String ?? ""
        diagnosedRevision = object["diagnosedRevision"] as? Int ?? -1
        proUnavailable = object["proUnavailable"] as? Bool ?? false
    }
}
