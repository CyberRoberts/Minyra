import Foundation
import SwiftUI

// Real pipeline integration: the AgentCore loop receives deterministic model
// tool calls, writes a broken app and a failing test, runs the test (nonzero),
// repairs the source, reruns the test (zero), independently reruns each
// acceptance criterion and must transition to Completed without extra calls.
//
// This is a MOCK-MODEL E2E test. It does not claim to test live DeepSeek,
// macOS 12 GUI rendering, or App Sandbox.
@MainActor
enum MiniAgentDeliveryE2E {
    private static func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MiniError("E2E assertion failed: " + message) }
    }

    static func perform() async -> Int {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniAgent-Delivery-E2E-" + UUID().uuidString, isDirectory: true)
        let old = AppConfig.load()
        defer {
            old.save()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = AppConfig(baseURL: "https://api.deepseek.com",
                                   model: "deepseek-flash", autoRun: true, tokenBudget: 0,
                                   autoRouting: false, fastModel: "", strongModel: "")
            config.save()
            // Before calling the model fixture, verify an ordinary Python
            // subprocess can actually run in the selected OS sandbox.
            let preflightRunner = LocalCommandRunner()
            let hello = await preflightRunner.run(["python3", "-c", "import os; print('SANDBOX_HELLO', os.getcwd())"],
                                                  cwd: root, projectRoot: root)
            guard hello.hasPrefix("退出码 0\n") && hello.contains("SANDBOX_HELLO") else {
                throw MiniError("Seatbelt project execution preflight failed: " + hello)
            }
            print("SEATBELT_PROJECT_PREFLIGHT_PASS")
            MiniAgentE2EFixture.replies = []
            MiniAgentE2EFixture.requests = 0

            let testScript = """
import unittest
from src.calc import add

class CalcTests(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)

if __name__ == "__main__":
    unittest.main()
"""
            let check = ["python3", "-m", "unittest", "discover", "-s", "tests", "-v"]
            func call(_ name: String, _ args: [String: Any], _ n: String) -> [String: Any] {
                MiniAgentE2EFixture.makeCall(name, args, "e2e-" + n)
            }
            MiniAgentE2EFixture.enqueue([
                call("set_acceptance_plan",
                     ["requirements": [
                        "加法函数必须通过实际 Python 单元测试",
                        "交付计算模块及可重复执行的测试代码"
                     ]], "plan"),
                call("write_file", ["path": "src/calc.py",
                                   "content": "def add(a, b):\n    return a - b\n"], "broken-source"),
                call("write_file", ["path": "tests/test_calc.py", "content": testScript], "tests")
            ])
            MiniAgentE2EFixture.enqueue([
                call("run_command", ["argv": check, "cwd": "."], "expected-failure")
            ])
            MiniAgentE2EFixture.enqueue([
                call("replace_in_file",
                     ["path": "src/calc.py", "old_text": "return a - b",
                      "new_text": "return a + b"], "repair")
            ])
            MiniAgentE2EFixture.enqueue([
                call("run_command", ["argv": check, "cwd": "."], "expected-pass")
            ])
            MiniAgentE2EFixture.enqueue([
                call("finish_task", [
                    "summary": "加法模块开发完成，并修复第一次单测发现的计算错误",
                    "artifacts": ["src/calc.py", "tests/test_calc.py"],
                    "checks": [
                        ["criterion_id": "C1", "argv": check, "cwd": "."],
                        ["criterion_id": "C2", "argv": check, "cwd": "."]
                    ],
                    "remaining": "仍需用户在真实 macOS 12 上测试 GUI 交互"
                ], "delivery")
            ])

            let agent = AgentCore()
            agent.workspace = MiniProject(root)
            agent.enableE2EKeyForDeliveryTest()
            try verify(agent.configured, "test-only Agent key was not accepted")
            agent.start("请创建并修好一个加法模块，提供真实单元测试并完成独立验收。")

            let expiry = Date().addingTimeInterval(55)
            var observedRunning = agent.running
            while agent.running && Date() < expiry {
                observedRunning = true
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if agent.running { agent.stop(); throw MiniError("Agent did not stop after independent delivery checks") }
            try verify(observedRunning, "Agent did not start")
            if agent.taskState.supervisor?.status != .completed {
                print("E2E_DIAG status=\(String(describing: agent.taskState.supervisor?.status)) calls=\(agent.apiCalls) tools=\(agent.toolOperations)")
                for event in agent.chat.suffix(28) {
                    print("E2E_DIAG " + String(event.message.prefix(700)))
                }
            }
            try verify(agent.taskState.supervisor?.status == .completed,
                       "supervisor is not Completed: " + agent.activity)
            try verify(agent.taskState.supervisor?.confirmedChecks.count == 2,
                       "all acceptance criteria were not independently re-executed")
            try verify(agent.taskState.supervisor?.completedArtifacts.count == 2,
                       "deliverables not stored in final task report")
            try verify(agent.taskState.verifiedRevision == agent.taskState.revision,
                       "last edits were not verified")
            try verify(agent.apiCalls == 5 && MiniAgentE2EFixture.requests == 5,
                       "unexpected additional paid/model request after completion")
            try verify(MiniAgentE2EFixture.replies.isEmpty, "fixture did not consume final delivery reply")
            let actual = try String(contentsOf: root.appendingPathComponent("src/calc.py"))
            try verify(actual.contains("return a + b"), "regression: wrong arithmetic code delivered")
            let failedTestWasObserved = agent.chat.contains {
                $0.message.contains("执行检查") && $0.message.contains("未通过")
            }
            try verify(failedTestWasObserved, "broken program never failed its first real test")
            let passedTestWasObserved = agent.chat.contains {
                $0.message.contains("执行检查") && $0.message.contains("通过")
            }
            try verify(passedTestWasObserved, "repaired program never passed its real test")
            print("AGENT_E2E_DELIVERY_PASS: wrote broken code -> real test failed -> repaired -> real test passed -> 2 independent checks -> Completed -> stopped at five fixture responses")
            print("AGENT_E2E_COUNTS requests=\(MiniAgentE2EFixture.requests) tool_ops=\(agent.toolOperations) acceptance_checks=\(agent.taskState.supervisor?.confirmedChecks.count ?? 0)")

            // Second offline end-to-end scenario: a model that keeps reading
            // an unchanged/nonexistent file MUST become Blocked after bounded
            // attempts. Never report Completed or spend endlessly.
            // Verify the actual operating-system child sandbox, not just
            // Swift's path checks. An AI-generated Python script must be able
            // to write its project, but NOT read or overwrite a user file
            // outside that folder, even if its argv is otherwise allowed.
            let protected = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiniAgent-E2E-Private-" + UUID().uuidString + ".txt")
            defer { try? FileManager.default.removeItem(at: protected) }
            try "private-dont-open".write(to: protected, atomically: true, encoding: .utf8)
            let projectScript = "from pathlib import Path; Path('sandbox-proof.txt').write_text('okay'); print('IN_PROJECT_OK')"
            let sandboxRunner = LocalCommandRunner()
            let inProject = await sandboxRunner.run(["python3","-c",projectScript],
                                                    cwd: root, projectRoot: root)
            try verify(inProject.hasPrefix("退出码 0\n") && inProject.contains("IN_PROJECT_OK"),
                       "sandbox blocked in-project Python: " + inProject)
            try verify(FileManager.default.fileExists(atPath: root.appendingPathComponent("sandbox-proof.txt").path),
                       "project command did not write file")
            let encoded = Data(protected.path.utf8).base64EncodedString()
            let outsideRead = "import base64; from pathlib import Path; print(Path(base64.b64decode('\(encoded)').decode()).read_text())"
            let attemptedRead = await sandboxRunner.run(["python3","-c", outsideRead],
                                                        cwd: root, projectRoot: root)
            try verify(!attemptedRead.hasPrefix("退出码 0\n") &&
                       !attemptedRead.contains("private-dont-open"),
                       "sandbox leaked a private file outside project: " + attemptedRead)
            let outsideWrite = "import base64; from pathlib import Path; Path(base64.b64decode('\(encoded)').decode()).write_text('overwrite')"
            let attemptedWrite = await sandboxRunner.run(["python3","-c",outsideWrite],
                                                         cwd: root, projectRoot: root)
            try verify(!attemptedWrite.hasPrefix("退出码 0\n"), "sandbox modified a file outside project")
            let protectedContent = try String(contentsOf: protected, encoding: .utf8)
            try verify(protectedContent == "private-dont-open",
                       "OS sandbox unexpectedly allowed external file modification")
            print("AGENT_E2E_SEATBELT_PASS: actual project Python write succeeded; external private read/write denied")

            let stalledRoot = root.appendingPathComponent("stalled-task", isDirectory: true)
            try FileManager.default.createDirectory(at: stalledRoot, withIntermediateDirectories: true)
            MiniAgentE2EFixture.replies = []
            MiniAgentE2EFixture.requests = 0
            for i in 0..<15 {
                MiniAgentE2EFixture.enqueue([
                    call("read_file", ["path": "missing.py", "start_line": 1,
                                       "end_line": 30], "repeated-read-\(i)")
                ])
            }
            let stalled = AgentCore()
            stalled.workspace = MiniProject(stalledRoot)
            stalled.enableE2EKeyForDeliveryTest()
            stalled.start("修复当前项目；若无文件与测试证据，必须阻断无效调用。")
            let blockedDeadline = Date().addingTimeInterval(30)
            while stalled.running && Date() < blockedDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if stalled.running {
                stalled.stop()
                throw MiniError("Repeated no-op tool calls did not terminate in time")
            }
            try verify(stalled.taskState.supervisor?.status == .blocked,
                       "runaway task was not safely Blocked: " + stalled.activity)
            try verify(MiniAgentE2EFixture.requests < 15,
                       "runaway task consumed all fixture requests instead of stopping")
            try verify(stalled.taskState.supervisor?.status != .completed,
                       "no-progress model incorrectly declared delivery Completed")
            print("AGENT_E2E_STALL_GUARD_PASS: repeated no-op model tool calls -> Blocked after \(MiniAgentE2EFixture.requests) offline requests, never falsely Completed")

            // Critical production regression: a previously Blocked task must
            // collect its own diagnostic evidence and finish using the SAME
            // saved task with ZERO additional user-authored requirements.
            MiniAgentE2EFixture.replies = []
            MiniAgentE2EFixture.requests = 0
            MiniAgentE2EFixture.enqueue([
                call("set_acceptance_plan",
                     ["requirements": [
                         "自动定位并修复加法函数代码错误",
                         "用真实单元测试证明修改后的代码可运行"
                     ]], "recovery-plan"),
                call("write_file", ["path": "src/calc.py",
                                    "content": "def add(a, b):\n    return a + b\n"], "recovery-source"),
                call("write_file", ["path": "tests/test_calc.py",
                                    "content": testScript], "recovery-tests")
            ])
            MiniAgentE2EFixture.enqueue([
                call("run_command", ["argv": check, "cwd": "."], "recovery-test")
            ])
            MiniAgentE2EFixture.enqueue([
                call("finish_task", [
                    "summary": "自动诊断后已修复原任务，并复测成功",
                    "artifacts": ["src/calc.py", "tests/test_calc.py"],
                    "checks": [
                        ["criterion_id": "C1", "argv": check, "cwd": "."],
                        ["criterion_id": "C2", "argv": check, "cwd": "."]
                    ]
                ], "recovery-finish")
            ])
            // NO new 'start' instruction. This is the old Blocked task.
            stalled.continueWork()
            let recoveryDeadline = Date().addingTimeInterval(35)
            while stalled.running && Date() < recoveryDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if stalled.running {
                stalled.stop()
                throw MiniError("Previously blocked task failed to finish unattended recovery")
            }
            try verify(stalled.taskState.supervisor?.status == .completed,
                       "blocked task did not self-diagnose and complete: " + stalled.activity)
            try verify(stalled.taskState.supervisor?.confirmedChecks.count == 2,
                       "recovered task did not independently rerun all checks")
            try verify(MiniAgentE2EFixture.requests == 3,
                       "recovery consumed unexpected model requests")
            try verify(stalled.chat.contains { $0.message.contains("本地自动诊断") || $0.message.contains("根据已保存") },
                       "no host-side self-diagnostic evidence before model repair")
            print("AGENT_E2E_SELF_DIAGNOSE_PASS: old Blocked task + no new user prompt -> automatic local diagnostic -> repaired code -> independent checks -> Completed")
            return 0
        } catch {
            print("AGENT_E2E_DELIVERY_FAILED: " + error.localizedDescription)
            return 1
        }
    }
}
