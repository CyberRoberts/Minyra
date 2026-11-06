import Foundation
import AppKit
import Combine
import CryptoKit

// Explicitly opted-in LOCAL packaging. Not an Actions runner and not a model tool.
// For now only the audited Ahaly QA script is accepted. The pinned Git blob
// prevents AI-edited project scripts from silently executing with host privileges.
@MainActor
final class MinyraLocalDelivery: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var stage = 0
    @Published private(set) var title = "本地打包待命"
    @Published private(set) var lines: [String] = []
    @Published private(set) var artifactPath: String?
    @Published private(set) var failed = false

    static let scriptPath = "tools/minyra_selfhost_qa_dmg.sh"
    // Git blob SHA of the reviewed script in CyberRoberts/Ahaly-for-Mac.
    static let approvedScriptBlob = "315e823db8388b99cd04604e9ab01c19f4374788"

    private var process: Process?
    private var partialLine = ""
    private var pendingArtifact: String?
    private var cancelled = false

    static func scriptBlobSHA(_ data: Data) -> String {
        var input = Data("blob \(data.count)\0".utf8)
        input.append(data)
        return Insecure.SHA1.hash(data: input)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func preflight(project: URL) -> String? {
        guard !CommandLine.arguments.contains("--agent-e2e-test"),
              !CommandLine.arguments.contains("--self-test") else {
            return "测试进程禁止实际执行本地交付脚本"
        }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 12,
              ProcessInfo.processInfo.environment["MINYRA_DISABLE_LOCAL_DELIVERY"] != "1" else {
            return "本地打包需要 macOS 12+，且未禁用本地执行"
        }
        guard project.appendingPathComponent("macos_stable/Resources/Info.plist").isFileURL,
              FileManager.default.fileExists(atPath: project.appendingPathComponent("macos_stable/Resources/Info.plist").path),
              FileManager.default.fileExists(atPath: project.appendingPathComponent("tools/build_mac_direct.sh").path) else {
            return "当前工程不是受支持的 Ahaly macOS 12 项目"
        }
        let script = project.appendingPathComponent(scriptPath)
        guard let data = try? Data(contentsOf: script), !data.isEmpty else {
            return "项目缺少可信的 tools/minyra_selfhost_qa_dmg.sh"
        }
        guard scriptBlobSHA(data) == approvedScriptBlob else {
            return "本地打包脚本已更改：需要先检查并重新批准脚本，拒绝运行未审核的命令"
        }
        guard !project.path.isEmpty, project.path != "/" else { return "工作目录不合法" }
        return nil
    }

    func start(project: URL) {
        guard !running else { return }
        failed = false
        stage = 0
        lines = []
        artifactPath = nil
        pendingArtifact = nil
        partialLine = ""
        cancelled = false

        if let error = Self.preflight(project: project) {
            failed = true
            title = error
            lines = [error]
            return
        }
        // This is a TRUSTED-PROJECT privilege boundary. We never execute
        // arbitrary AI-issued shell commands through this code path.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [project.appendingPathComponent(Self.scriptPath).path]
        p.currentDirectoryURL = project
        let original = ProcessInfo.processInfo.environment
        var clean = [
            "PATH": original["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": original["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": original["LC_ALL"] ?? "en_US.UTF-8"
        ]
        if let developer = original["DEVELOPER_DIR"], !developer.isEmpty {
            clean["DEVELOPER_DIR"] = developer
        }
        p.environment = clean
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.acceptOutput(data) }
        }
        do {
            running = true
            title = "准备执行本地 QA · 不使用 GitHub Actions"
            append("本机执行、无自动上传；生成的是内部测试 DMG，不是已公证的正式版。")
            try p.run()
            process = p
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                p.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async {
                    self?.acceptOutput(tail)
                    self?.finish(exitCode: p.terminationStatus)
                }
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            running = false
            failed = true
            title = "无法启动本地交付"
            append(error.localizedDescription)
        }
    }

    func stop() {
        guard running else { return }
        cancelled = true
        title = "正在停止本地打包…"
        process?.terminate()
    }

    func revealArtifact() {
        guard let path = artifactPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func append(_ line: String) {
        let clean = String(line.prefix(600))
        guard !clean.isEmpty else { return }
        lines.append(clean)
        if lines.count > 160 { lines.removeFirst(lines.count - 160) }
        if clean.contains("[1/5]") { stage = max(stage, 1); title = "1/5 · 运行项目测试" }
        if clean.contains("[2/5]") { stage = max(stage, 2); title = "2/5 · Intel 原生编译" }
        if clean.contains("[3/5]") { stage = max(stage, 3); title = "3/5 · 检查图标与签名" }
        if clean.contains("[4/5]") { stage = max(stage, 4); title = "4/5 · 制作本地 DMG" }
        if clean.contains("[5/5]") { stage = max(stage, 5); title = "5/5 · 验证安装包" }
        if clean.hasPrefix("MINYRA_LOCAL_DMG_PASS: ") {
            pendingArtifact = String(clean.dropFirst("MINYRA_LOCAL_DMG_PASS: ".count))
        }
    }

    private func acceptOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        partialLine += String(decoding: data, as: UTF8.self)
        let components = partialLine.components(separatedBy: "\n")
        partialLine = components.last ?? ""
        for line in components.dropLast() {
            append(line.trimmingCharacters(in: .newlines))
        }
        if partialLine.count > 8000 {
            append(String(partialLine.prefix(600)))
            partialLine = ""
        }
    }

    private func finish(exitCode: Int32) {
        if !partialLine.isEmpty { append(partialLine); partialLine = "" }
        running = false
        process = nil
        if cancelled {
            failed = true
            title = "用户已停止 · 未交付"
            append("停止了本地构建；请检查是否仍有编译子进程运行。")
            return
        }
        guard exitCode == 0 else {
            failed = true
            title = "本地构建失败 · 退出码 \(exitCode)"
            append("打包失败，不会把未通过验证的 DMG 标记为完成。")
            return
        }
        guard let path = pendingArtifact,
              path.hasSuffix(".dmg"),
              FileManager.default.fileExists(atPath: path),
              FileManager.default.fileExists(atPath: path + ".sha256"),
              let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
              size.int64Value > 0 else {
            failed = true
            title = "构建进程退出，但找不到经过验证的 DMG"
            append("未检测到可信的 MINYRA_LOCAL_DMG_PASS 标记和安装包校验文件。")
            return
        }
        artifactPath = path
        stage = 5
        title = "本地 QA DMG 已生成 · 未公证"
        append("交付完成：" + path)
    }
}
