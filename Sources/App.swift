import SwiftUI
import AppKit
import Foundation
import Darwin

@main
struct MiniCodingAgentApp: App {
    @StateObject private var agent = AgentCore()
    init() {
        if CommandLine.arguments.contains("--self-test") {
            // AppKit views are main-actor-isolated. Enter that actor explicitly
            // even for this command-line-only native UI regression test.
            Task { @MainActor in
                let code = await MiniSelfTest.perform()
                fflush(stdout)
                exit(Int32(code))
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--agent-e2e-test") {
            // Exercise the genuine main-actor AgentCore event loop with a
            // deterministic offline model fixture; never open a GUI window.
            Task { @MainActor in
                let code = await MiniAgentDeliveryE2E.perform()
                fflush(stdout)
                exit(Int32(code))
            }
            RunLoop.main.run()
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(agent)
                .frame(minWidth: 800, minHeight: 550)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}

@MainActor
private enum MiniSelfTest {
    @MainActor
    static func perform() async -> Int {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("miniagent-test-" + UUID().uuidString, isDirectory: true)
        let sample = fm.temporaryDirectory.appendingPathComponent("miniagent-sample-" + UUID().uuidString + ".txt")
        defer { try? fm.removeItem(at: folder); try? fm.removeItem(at: sample) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try await MiniCharacterGestureQA.perform()
            let project = MiniProject(folder)
            _ = try project.write("src/main.py", "print('hi')\n")
            guard try project.read("src/main.py") == "print('hi')\n" else { throw MiniError("read/write 测试失败") }
            guard try project.readRange("src/main.py", from: 1, to: 1).contains("L1: print('hi')") else { throw MiniError("分段读取测试失败") }
            _ = try project.replace("src/main.py", old: "hi", new: "hello")
            guard try project.read("src/main.py") == "print('hello')\n" else { throw MiniError("replace 测试失败") }
            // The original source must be recoverable after every real edit.
            let backups = try project.availableBackups("src/main.py")
            guard backups.count == 1,
                  try String(contentsOf: backups[0], encoding: .utf8) == "print('hi')\n",
                  !project.backupDirectory.path.hasPrefix(folder.path + "/") else {
                throw MiniError("修改前自动备份不存在、内容错误或位于不安全的项目目录")
            }
            _ = try project.write("src/main.py", "print('hello')\n")
            guard try project.availableBackups("src/main.py").count == 1 else {
                throw MiniError("无变化写入仍然生成无用备份")
            }
            let restoredSource = try String(contentsOf: backups[0], encoding: .utf8)
            guard restoredSource == "print('hi')\n" else {
                throw MiniError("备份文件无法恢复原始源码")
            }

            guard try project.listing().contains("src/main.py") else { throw MiniError("list 测试失败") }
            var blocked = false
            do { _ = try project.read("../private") } catch { blocked = true }
            guard blocked else { throw MiniError("目录穿越防护失败") }
            try "payload".write(to: sample, atomically: true, encoding: .utf8)
            let imported = project.importFiles([sample])
            guard imported.first?.contains("已添加") == true else { throw MiniError("import 测试失败") }
            guard JSONSerialization.isValidJSONObject(AIService.toolDefinitions) else { throw MiniError("Tool definitions JSON 无效") }
            guard MiniModelRouter.difficulty("读一下配置") == .simple else { throw MiniError("简单任务路由错误") }
            guard MiniModelRouter.difficulty("从零构建完整网站，包含数据库、后端和部署") == .complex else { throw MiniError("复杂任务路由错误") }
            let quick = MiniModelRouter.choose(baseURL: "https://api.deepseek.com", configured: "deepseek-chat", auto: true,
                fast: "", strong: "", goal: "读一下配置")
            guard quick.model == "deepseek-flash" && quick.effort == "none" else { throw MiniError("Flash 路由错误") }
            let complex = MiniModelRouter.choose(baseURL: "https://api.deepseek.com", configured: "deepseek-chat", auto: true,
                fast: "", strong: "", goal: "修复编译错误", failures: 2)
            guard complex.model == "deepseek-v4-pro" && complex.effort == "high" else { throw MiniError("Pro 诊断路由错误") }
            // The 12-frame native character sequence must never jump 11 -> 0.
            // Regression: former hard wrap caused an obvious shudder every 1.44 s.
            var frameIndex = 0
            var direction = 1
            var visited: Set<Int> = [0]
            for _ in 0..<66 {
                let next = MiniFramePlayback.advance(index: frameIndex,
                                                     direction: direction, count: 12)
                guard next.index >= 0, next.index < 12,
                      abs(next.index - frameIndex) == 1 else {
                    throw MiniError("Mini 酱动画发生跨帧跳变")
                }
                frameIndex = next.index
                direction = next.direction
                visited.insert(frameIndex)
            }
            guard visited.count == 12,
                  MiniFramePlayback.advance(index: 11, direction: 1, count: 12).index == 10,
                  MiniFramePlayback.advance(index: 0, direction: -1, count: 12).index == 1 else {
                throw MiniError("Mini 酱动画播放循环错误")
            }
            // Explicit manual model must never be silently overridden by
            // complexity, failures or automatic specialist routing.
            for chosen in ["deepseek-flash", "deepseek-v4-pro", "user-custom-model"] {
                let manual = MiniModelRouter.choose(baseURL: "https://api.deepseek.com",
                    configured: chosen, auto: false, fast: "deepseek-flash",
                    strong: "deepseek-v4-pro", goal: "构建复杂软件并修复错误",
                    failures: 4)
                guard manual.model == chosen && manual.effort == nil else {
                    throw MiniError("手动模型被意外切换：" + chosen)
                }
            }
            let external = MiniModelRouter.choose(baseURL: "https://other.example/v1", configured: "custom", auto: true,
                fast: "", strong: "", goal: "修复错误", failures: 2)
            guard external.model == "custom" && external.effort == nil else { throw MiniError("非 DeepSeek 路由错误") }
            // Regression: never spend API tokens on impossible delivery when
            // local tests have not been authorized by the user.
            guard AgentDeliveryPolicy.blocker(autoRunEnabled: true) == nil,
                  let denied = AgentDeliveryPolicy.blocker(autoRunEnabled: false),
                  denied.contains("测试") && denied.contains("API") else {
                throw MiniError("未开启本地测试却允许无效 AI 请求")
            }
            try AgentCore().selfTestVerificationEvidence()
            // A green unit-test suite is a subsystem checkpoint, not proof
            // that the entire user's deliverable is finished. After green
            // diagnostics Minyra must inspect outstanding acceptance criteria
            // instead of blindly rewriting the passing module.
            let green = AgentDiagnosticPolicy.nextStep(testPassed: true,
                         criteriaCount: 4, revision: 6)
            let baseline = AgentDiagnosticPolicy.nextStep(testPassed: true,
                            criteriaCount: 0, revision: 0)
            let red = AgentDiagnosticPolicy.nextStep(testPassed: false,
                      criteriaCount: 4, revision: 6)
            guard green.contains("finish_task") && green.contains("尚未满足"),
                  baseline.contains("set_acceptance_plan"),
                  red.contains("修复") && !red.contains("finish_task") else {
                throw MiniError("自动诊断把测试通过误判为整个项目已完成，或未提出下一项验收工作")
            }
            // Regression: a new strategy must NOT keep buying unlimited
            // model requests when no file/test evidence changes.
            guard !AgentRecoveryPolicy.exhausted(sameRevision: 2, total: 4),
                  AgentRecoveryPolicy.exhausted(sameRevision: 3, total: 1),
                  AgentRecoveryPolicy.exhausted(sameRevision: 1, total: 5) else {
                throw MiniError("自动恢复费用安全闸门错误")
            }
            var stalled = AgentStallGuard()
            for index in 0..<21 {
                let signal = stalled.observe(signature: "read_file|sample-\(index)",
                                             result: "same-output-\(index)",
                                             isProgress: false, failedTest: false)
                guard signal == nil else { throw MiniError("空转检测错误：过早阻断") }
            }
            guard stalled.observe(signature: "read_file|last", result: "unchanged",
                                  isProgress: false, failedTest: false) != nil else {
                throw MiniError("连续 22 步无进展仍未报警")
            }
            stalled.beginRecoveryWindow()
            guard stalled.observe(signature: "read_file|next", result: "unchanged",
                                  isProgress: false, failedTest: false) == nil else {
                throw MiniError("自动恢复检查窗口未正确启动")
            }
            var repeatedEdit = AgentStallGuard()
            for _ in 0..<2 {
                guard repeatedEdit.observe(signature: "write_file|sample",
                                           result: "unchanged-sha",
                                           isProgress: true, failedTest: false) == nil else {
                    throw MiniError("错误检测到首次代码修改往返")
                }
            }
            repeatedEdit.beginRecoveryWindow()
            guard repeatedEdit.observe(signature: "write_file|sample",
                                       result: "unchanged-sha",
                                       isProgress: true, failedTest: false) != nil else {
                throw MiniError("恢复策略错误地清除了重复写入证据")
            }
            // Long resumed conversations must never contain orphaned tool results.
            var historyFixture: [[String: Any]] = [["role": "system", "content": "agent"]]
            for i in 0..<50 { historyFixture.append(["role": "user", "content": "step \(i)"]) }
            historyFixture.append(["role": "assistant", "tool_calls": [
                ["id": "one", "function": ["name": "read_file", "arguments": "{}"]],
                ["id": "two", "function": ["name": "write_file", "arguments": "{}"]]
            ]])
            historyFixture.append(["role": "tool", "tool_call_id": "one", "content": "read ok"])
            historyFixture.append(["role": "tool", "tool_call_id": "two", "content": "write ok"])
            let compact = AgentContextPolicy.trimStoredHistory(historyFixture)
            guard compact.count <= 42,
                  compact.last?["tool_call_id"] as? String == "two",
                  compact.contains(where: { $0["tool_call_id"] as? String == "one" }) else {
                throw MiniError("恢复上下文时破坏了多工具调用配对")
            }
            guard !AgentContextPolicy.hasPendingToolCalls(historyFixture) else {
                throw MiniError("完整工具调用被错误标记为未完成")
            }
            historyFixture.removeLast()
            guard AgentContextPolicy.hasPendingToolCalls(historyFixture) else {
                throw MiniError("未完成多工具调用未被发现，存在记录损坏风险")
            }
            let interrupted = AgentContextPolicy.trimStoredHistory(historyFixture)
            guard !interrupted.contains(where: { $0["tool_call_id"] as? String == "one" }) else {
                throw MiniError("历史裁剪保留了未完成工具调用")
            }
            var supervision = AcceptanceSupervisor()
            supervision.startFresh()
            guard supervision.registerPlan(["启动程序不报错", "创建后的数据可以读取"]) != nil else { throw MiniError("验收计划未建立") }
            let requests = [AcceptanceCheckRequest(criterionID: "C1", argv: ["python3", "main.py"], cwd: "."),
                            AcceptanceCheckRequest(criterionID: "C2", argv: ["python3", "tests/test_data.py"], cwd: ".")]
            guard supervision.preflight(artifacts: ["main.py"], checks: requests, changedRevision: 1) == nil else { throw MiniError("验收计划校验错误") }
            let fake = [AcceptanceCheckRequest(criterionID: "C1", argv: ["echo", "passed"], cwd: "."), requests[1]]
            guard supervision.preflight(artifacts: ["main.py"], checks: fake, changedRevision: 1) != nil else { throw MiniError("伪造验收命令未被拦截") }
            guard supervision.preflight(artifacts: ["main.py"], checks: requests.prefix(1).map { $0 }, changedRevision: 1) != nil else { throw MiniError("验收缺失检测失败") }
            guard supervision.rejection("测试失败", revision: 1) == false else { throw MiniError("过早阻断") }
            guard supervision.rejection("测试失败", revision: 1) == false else { throw MiniError("过早阻断") }
            guard supervision.rejection("测试失败", revision: 1) && supervision.status == .blocked else { throw MiniError("重复失败阻断无效") }
            guard AgentAPIRetryPolicy.shouldRetry(1), AgentAPIRetryPolicy.shouldRetry(4),
                  !AgentAPIRetryPolicy.shouldRetry(5), !AgentAPIRetryPolicy.shouldRetry(100) else {
                throw MiniError("外部 API 故障重试没有上限")
            }
            let busy = APIHTTPError(statusCode: 503, message: "Service is too busy", retryAfterSeconds: nil)
            let unauth = APIHTTPError(statusCode: 401, message: "Invalid API key", retryAfterSeconds: nil)
            guard busy.isTransient && !unauth.isTransient else { throw MiniError("API 状态分类错误") }
            guard busy.retryDelaySeconds == 3 else { throw MiniError("API 重试等待时间异常") }
            guard busy.errorDescription?.contains("HTTP 503") == true && !busy.errorDescription!.contains("原地打转") else { throw MiniError("503 错误文案不正确") }
            guard try AIService.endpoint(from: "https://api.example.com/v1").absoluteString == "https://api.example.com/v1/chat/completions" else { throw MiniError("API URL 无效") }
            if Bundle.main.bundleIdentifier != "io.github.cyberroberts.minyra.opensource" {
            // Cubism export is real and bundled; do not mistake existence
            // for successful rendering. That must be tested in WKWebView later.
            guard let cubism = Bundle.main.resourceURL?.appendingPathComponent("Live2D", isDirectory: true) else {
                throw MiniError("Cubism 模型目录不存在")
            }
            let modelFile = cubism.appendingPathComponent("MiniChan_RigReady.model3.json")
            let binary = cubism.appendingPathComponent("MiniChan_RigReady.moc3")
            let texture = cubism.appendingPathComponent("MiniChan_RigReady.4096/texture_00.png")
            guard fm.fileExists(atPath: modelFile.path),
                  fm.fileExists(atPath: texture.path),
                  (try? Data(contentsOf: binary).prefix(4)) == Data([0x4d, 0x4f, 0x43, 0x33])
            else { throw MiniError("Live2D Cubism 导出模型文件不完整") }
            guard let playerRoot = Bundle.main.resourceURL?.appendingPathComponent("Live2DWeb", isDirectory: true) else {
                throw MiniError("缺少动态角色播放器目录")
            }
            let runtimeFile = playerRoot.appendingPathComponent("p2l_runtime.wasm")
            let webModel = playerRoot.appendingPathComponent("MiniChan.p2lrt")
            let webPage = playerRoot.appendingPathComponent("index.html")
            guard FileManager.default.fileExists(atPath: webPage.path),
                  FileManager.default.fileExists(atPath: webModel.path),
                  FileManager.default.fileExists(atPath: playerRoot.appendingPathComponent("p2l.js").path),
                  (try? Data(contentsOf: runtimeFile).prefix(4)) == Data([0, 97, 115, 109]),
                  let page = try? String(contentsOf: webPage, encoding: .utf8),
                  page.contains("miniSetMood"), page.contains("miniCharacterHealth")
            else { throw MiniError("Live2D WebAssembly 播放器文件缺失或不完整") }
            // Mini Chat must remain tool-free regardless of coding Agent settings.
            guard let framesRoot = Bundle.main.resourceURL?.appendingPathComponent("Live2DFrames", isDirectory: true) else {
                throw MiniError("缺少 Mini 酱透明动画帧")
            }
            let pngSignature = Data([137,80,78,71,13,10,26,10])
            for mood in ["idle", "talk", "think", "happy"] {
                for frame in 0..<12 {
                    let filename = String(format: "%03d.png", frame)
                    let path = framesRoot.appendingPathComponent(mood).appendingPathComponent(filename)
                    guard let data = try? Data(contentsOf: path),
                          data.count > 1000,
                          data.prefix(8) == pngSignature else {
                        throw MiniError("Mini 酱原生透明动画帧缺失：" + mood + "/" + filename)
                    }
                }
            }
            }
            let miniTestConfig = MiniChatConfig(modelChoice: "deepseek-flash", customModel: "",
                                                thinking: false, reuseAgentKey: false)
            let miniPayload = MiniChatAPI.payload(config: miniTestConfig,
                                                    history: [MiniCompanionLine(.user, "你好")])
            guard miniPayload["tools"] == nil, miniPayload["tool_choice"] == nil,
                  miniPayload["model"] as? String == "deepseek-flash",
                  let miniThinking = miniPayload["thinking"] as? [String: String],
                  miniThinking["type"] == "disabled" else {
                throw MiniError("Mini 酱聊天配置可能混入编程 Agent 工具权限")
            }
            print("SELF_TEST_OK: files / replace / traversal / import / API schema / endpoint / supervisor / fake-tests-rejected / HTTP 503 classified / model routing / separate tool-free Mini chat / genuine Cubism assets / playable rig WASM")
            return 0
        } catch {
            fputs("SELF_TEST_FAILED: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
