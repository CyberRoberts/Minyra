import Foundation
import AppKit
import Security

struct AppConfig {
    // E2E fixtures must never mutate a real user's saved API/model settings.
    // In test mode a separate per-process preference domain is used.
    private static var configDefaults: UserDefaults {
        if CommandLine.arguments.contains("--agent-e2e-test"),
           let isolated = UserDefaults(suiteName: "com.minicodingagent.native.e2e.\(ProcessInfo.processInfo.processIdentifier)") {
            return isolated
        }
        return .standard
    }
    var baseURL: String
    var model: String
    var autoRun: Bool
    var tokenBudget: Int
    var autoRouting: Bool = true
    var fastModel: String = ""
    var strongModel: String = ""

    static func load() -> AppConfig {
        let defaults = Self.configDefaults
        return AppConfig(baseURL: defaults.string(forKey: "apiBaseURL") ?? "",
                         model: defaults.string(forKey: "apiModel") ?? "",
                         autoRun: defaults.bool(forKey: "allowLocalRun"),
                         tokenBudget: defaults.object(forKey: "safetyTokenBudget") as? Int ?? 0,
                         autoRouting: defaults.object(forKey: "autoModelRouting") as? Bool ?? true,
                         fastModel: defaults.string(forKey: "fastModelID") ?? "",
                         strongModel: defaults.string(forKey: "strongModelID") ?? "")
    }
    func save() {
        let d = Self.configDefaults
        d.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiBaseURL")
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiModel")
        d.set(autoRun, forKey: "allowLocalRun")
        d.set(tokenBudget, forKey: "safetyTokenBudget")
        d.set(autoRouting, forKey: "autoModelRouting")
        d.set(fastModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "fastModelID")
        d.set(strongModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "strongModelID")
    }
}

enum APIKeychain {
    private static let service = "com.minicodingagent.native.api"
    private static let account = "user-supplied-key"
    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let d = result as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        if key.isEmpty { return }
        var add = q
        add[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { throw MiniError("API Key 保存到 Mac 钥匙串失败（错误码 \(status)）") }
    }
}

struct MiniError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct MiniProject {
    let root: URL
    init(_ url: URL) { root = url.standardizedFileURL.resolvingSymlinksInPath() }

    static func automatic() -> MiniProject {
        if CommandLine.arguments.contains("--agent-e2e-test") {
            let testRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("Minyra-E2E-Workspace-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
            return MiniProject(testRoot)
        }
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "projectRoot"), FileManager.default.fileExists(atPath: saved) {
            return MiniProject(URL(fileURLWithPath: saved))
        }
        let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("MiniAgent 工作站/我的项目", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        d.set(root.path, forKey: "projectRoot")
        return MiniProject(root)
    }
    func remember() {
        guard !CommandLine.arguments.contains("--agent-e2e-test") else { return }
        UserDefaults.standard.set(root.path, forKey: "projectRoot")
    }

    // Backups are OUTSIDE the executable project sandbox. AI-generated build
    // scripts cannot erase them, and they never enter the chat/API context.
    // Each changed existing file is copied before the atomic replacement.
    var backupDirectory: URL {
        var hash: UInt64 = 14695981039346656037
        for byte in root.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let base: URL
        if CommandLine.arguments.contains("--self-test") ||
           CommandLine.arguments.contains("--agent-e2e-test") {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Minyra-Test-Backups-\\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MinyraOpenSource/Backups", isDirectory: true)
        }
        return base.appendingPathComponent(String(hash, radix: 16), isDirectory: true)
    }

    private func backupBeforeEdit(_ source: URL, relative: String) throws {
        let backupFolder = backupDirectory.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        // The UUID preserves every version even for edits in the same second.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = backupFolder.appendingPathComponent(stamp + "-" +
            UUID().uuidString + ".bak")
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func availableBackups(_ relative: String) throws -> [URL] {
        _ = try safeURL(relative)
        let folder = backupDirectory.appendingPathComponent(relative, isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: nil))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    func safeURL(_ relative: String, mustExist: Bool = false) throws -> URL {
        let path = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path.hasPrefix("/") || path.contains("\\") || path.contains("\0") || path.components(separatedBy: "/").contains("..") {
            throw MiniError("只允许项目内的相对路径：\(relative)")
        }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw MiniError("文件路径超出工作目录") }
        var walk = root
        for part in path.split(separator: "/") {
            walk.appendPathComponent(String(part))
            if (try? FileManager.default.attributesOfItem(atPath: walk.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw MiniError("项目文件禁止跨越符号链接")
            }
        }
        if mustExist && !FileManager.default.fileExists(atPath: url.path) { throw MiniError("文件不存在：\(path)") }
        return url
    }

    func listing(_ relative: String = ".") throws -> String {
        let start = try safeURL(relative, mustExist: true)
        guard (try? start.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw MiniError("不是目录") }
        let ignored: Set<String> = [".git", "node_modules", "__pycache__", ".venv", "dist", "build", ".next", ".DS_Store", ".miniagent"]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return "(空项目)" }
        var entries: [String] = []
        while let item = walker.nextObject() as? URL {
            let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if ignored.contains(item.lastPathComponent) || v?.isSymbolicLink == true {
                walker.skipDescendants(); continue
            }
            let suffix = v?.isDirectory == true ? "/" : ""
            let relativeName = String(item.path.dropFirst(root.path.count + 1))
            entries.append(relativeName + suffix)
            if entries.count >= 240 { entries.append("…前 240 项"); break }
        }
        return entries.isEmpty ? "(空项目)" : entries.sorted().joined(separator: "\n")
    }
    func read(_ relative: String) throws -> String {
        let url = try safeURL(relative, mustExist: true)
        let name = url.lastPathComponent.lowercased()
        if [".env", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", "credentials.json", "secrets.json"].contains(name) ||
            (name.hasPrefix(".env.") && ![".env.example", ".env.sample", ".env.template"].contains(name)) ||
            name.hasSuffix(".pem") || name.hasSuffix(".key") { throw MiniError("已阻止读取包含密钥的文件") }
        if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 350_000 { throw MiniError("文件超过 350 KB，请分段读取") }
        let bytes = try Data(contentsOf: url)
        guard let text = String(data: bytes, encoding: .utf8) else { throw MiniError("只支持读取 UTF-8 文本文件") }
        return String(text.prefix(150_000))
    }
    func readRange(_ relative: String, from startLine: Int?, to endLine: Int?) throws -> String {
        let source = try read(relative)
        let lines = source.components(separatedBy: "\n")
        let first = max(1, startLine ?? 1)
        let last = min(lines.count, endLine ?? (first + 110))
        guard first <= lines.count, last >= first, last - first <= 220 else {
            throw MiniError("读取范围无效，请一次最多请求 221 行；文件共有 \(lines.count) 行")
        }
        var preview = "文件：\(relative) · 共 \(lines.count) 行 · 目前显示 L\(first)–L\(last)\n"
        for index in (first - 1)..<last {
            let line = "L\(index + 1): " + lines[index] + "\n"
            if preview.count + line.count > 9500 {
                preview += "…当前片段长度已限制，请继续用 start_line / end_line 定位。\n"
                break
            }
            preview += line
        }
        return preview
    }

    func write(_ relative: String, _ content: String) throws -> String {
        if content.utf8.count > 750_000 { throw MiniError("单次写入超过 750KB") }
        let url = try safeURL(relative)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue { throw MiniError("不能覆盖文件夹") }
        let existing = fm.fileExists(atPath: url.path)
        if existing, (try? String(contentsOf: url, encoding: .utf8)) == content {
            return "内容未变化：\\(relative)"
        }
        if existing {
            // Refuse to replace unexpectedly large/binary project artifacts
            // with a text tool; preserve all older bytes before this edit.
            let originalSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard originalSize <= 5_000_000 else {
                throw MiniError("原文件超过 5 MB，禁止用文本工具覆盖，请采用专项构建流程")
            }
            try backupBeforeEdit(url, relative: relative)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "已保存 \(relative)（\(content.count) 字符）"
    }
    func replace(_ relative: String, old: String, new: String) throws -> String {
        if old.isEmpty { throw MiniError("被替换内容不能为空") }
        let source = try read(relative)
        let hits = source.components(separatedBy: old).count - 1
        if hits != 1 { throw MiniError("要替换的文字匹配到 \(hits) 处，请提供精确上下文") }
        return try write(relative, source.replacingOccurrences(of: old, with: new))
    }

    func importFiles(_ urls: [URL]) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        for url in urls {
            do {
                let src = url.standardizedFileURL.resolvingSymlinksInPath()
                if src.path == root.path || src.path.hasPrefix(root.path + "/") { results.append("已在项目中：" + src.lastPathComponent); continue }
                var dest = root.appendingPathComponent(src.lastPathComponent)
                var index = 2
                while fm.fileExists(atPath: dest.path) {
                    let stem = src.deletingPathExtension().lastPathComponent
                    let ext = src.pathExtension
                    dest = root.appendingPathComponent("\(stem)-\(index)" + (ext.isEmpty ? "" : ".\(ext)"))
                    index += 1
                }
                // Copy instead of moving; original project stays untouched.
                try fm.copyItem(at: src, to: dest)
                results.append("已添加：" + dest.lastPathComponent)
                if src.pathExtension.lowercased() == "zip" {
                    // Keep ZIP intact so user has the original archive even if extraction fails.
                    let extracted = try? unzipSafe(dest)
                    if let note = extracted { results.append(note) }
                }
            } catch { results.append("导入失败：\(url.lastPathComponent)（\(error.localizedDescription)）") }
        }
        return results
    }

    // Extract using a path/symlink-checked standard-library helper. No remote downloads.
    private func unzipSafe(_ archive: URL) throws -> String {
        let name = archive.deletingPathExtension().lastPathComponent + "_解压"
        let target = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { return "ZIP 已导入；同名解压目录存在，未覆盖" }
        let code = """
import os, sys, zipfile, shutil, stat
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=False)
with zipfile.ZipFile(src, 'r') as z:
    entries = z.infolist()
    if len(entries) > 5000 or sum(x.file_size for x in entries) > 500000000:
        raise ValueError('ZIP too large')
    for x in entries:
        name = x.filename.replace('\\', '/')
        parts = name.split('/')
        if name.startswith('/') or '..' in parts or any(p == '' for p in parts[:-1]):
            raise ValueError('Unsafe ZIP member')
        if stat.S_IFMT(x.external_attr >> 16) == stat.S_IFLNK:
            raise ValueError('Symlink in ZIP')
        dest = os.path.abspath(os.path.join(dst, name))
        if os.path.commonpath([os.path.abspath(dst), dest]) != os.path.abspath(dst):
            raise ValueError('ZIP escaped project')
        if x.is_dir():
            os.makedirs(dest, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with z.open(x, 'r') as inp, open(dest, 'wb') as out:
                shutil.copyfileobj(inp, out, 1024*1024)
"""
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        job.arguments = ["-c", code, archive.path, target.path]
        let err = Pipe()
        job.standardError = err
        job.standardOutput = Pipe()
        do {
            try job.run()
            let details = err.fileHandleForReading.readDataToEndOfFile()
            job.waitUntilExit()
            if job.terminationStatus != 0 { throw MiniError("ZIP 无法安全解压：" + String(decoding: details.prefix(300), as: UTF8.self)) }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return "已自动解压项目：" + name
    }

}
