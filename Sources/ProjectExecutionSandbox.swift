import Foundation
import Darwin

// A macOS Seatbelt restriction for the build/test CHILD PROCESS only.
//
// IMPORTANT: This does not enable com.apple.security.app-sandbox for the GUI.
// Apple has deprecated sandbox-exec, but it is available in Monterey and
// currently supported in the cloud build. Treat lack of this binary or a
// rejected policy as a hard failure, never silently launch an unrestricted
// subprocess.
//
// Model-originated commands can access their explicitly chosen workspace and
// necessary system toolchains. They cannot read the user's SSH credentials,
// browsing profile, unrelated projects or home files. Temporary build files,
// package caches and HOME are redirected inside the workspace. External
// networking is disabled for ordinary tests; localhost integration tests work.
//
// A future signed, full App Sandbox + isolated XPC/VM worker is needed before
// calling the WHOLE application a system-sandboxed production release.
enum ProjectExecutionSandbox {
    static let executable = "/usr/bin/sandbox-exec"

    static let profile = """
    (version 1)
    (deny default)
    (allow process*)
    (allow mach-lookup)
    (allow signal)
    (allow sysctl-read)
    (allow file-read-metadata)
    (allow file-read*
        (literal "/")
        (literal (param "PARENT_0"))
        (literal (param "PARENT_1"))
        (literal (param "PARENT_2"))
        (literal (param "PARENT_3"))
        (literal (param "PARENT_4"))
        (literal (param "PARENT_5"))
        (literal (param "PARENT_6"))
        (literal (param "PARENT_7"))
        (literal (param "PARENT_8"))
        (literal (param "PARENT_9"))
        (literal (param "PARENT_10"))
        (literal (param "PARENT_11"))
        (literal (param "PARENT_12"))
        (literal (param "PARENT_13"))
        (literal (param "PARENT_14"))
        (literal (param "PARENT_15"))
        (subpath (param "PROJECT_ROOT"))
        (subpath (param "PY_RUNTIME"))
        (subpath "/System")
        (subpath "/usr")
        (subpath "/bin")
        (subpath "/sbin")
        (subpath "/Library")
        (subpath "/Applications")
        (subpath "/opt")
        (subpath "/private/etc")
        (subpath "/private/tmp")
        (subpath "/dev")
    )
    (allow file-write*
        (subpath (param "PROJECT_ROOT"))
        (literal "/dev/null")
        (literal "/dev/stdout")
        (literal "/dev/stderr")
    )
    (allow network* (local ip "localhost:*"))
    (allow network* (remote ip "localhost:*"))
    (allow network* (remote unix-socket))
    """

    // Python interpreters may be symlinked from /usr/local/bin into a
    // separate framework/hostedtoolcache installation. Allow that exact
    // interpreter distribution for reading stdlib modules, NOT the entire
    // home folder. This trusted lookup never invokes model-controlled code.
    private static let pythonRuntime: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c",
                       "import os,sys;print(os.path.commonpath([os.path.realpath(x) for x in (sys.executable,sys.prefix,sys.base_prefix)]))"]
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let raw = stdout.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: raw, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var isDir: ObjCBool = false
            if p.terminationStatus == 0, path.hasPrefix("/"), path != "/",
               path.count > 5,
               FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
               isDir.boolValue {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        } catch { }
        // System Python already lives under /usr; don't broaden access if
        // an external interpreter cannot be identified safely.
        return "/usr"
    }()

    // URL.resolvingSymlinksInPath() does not always normalize macOS's
    // /var -> /private/var filesystem alias (notably on GitHub Intel Macs).
    // Seatbelt compares physical vnode paths, so use POSIX realpath here.
    static func physicalURL(_ url: URL) throws -> URL {
        guard let ptr = url.path.withCString({ Darwin.realpath($0, nil) }) else {
            throw MiniError("无法解析项目的真实磁盘路径：" + url.path)
        }
        defer { Darwin.free(ptr) }
        return URL(fileURLWithPath: String(cString: ptr), isDirectory: true)
    }

    static func wrappedArguments(_ argv: [String], projectRoot: URL) throws -> [String] {
        let root = try physicalURL(projectRoot)
        guard root.isFileURL,
              root.path != "/",
              root.path.count > 5,
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw MiniError("系统命令隔离工具不可用，已阻止运行未受保护的项目脚本")
        }
        // getcwd()/realpath() require directory traversal through every
        // ancestor of the workspace. Grant access to those EXACT directories
        // only, not to their children or sibling projects/user secrets.
        var ancestor = root.deletingLastPathComponent()
        var parents: [String] = []
        for index in 0..<16 {
            parents.append("-D")
            parents.append("PARENT_\(index)=" + ancestor.path)
            if ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        }
        return ["-D", "PROJECT_ROOT=" + root.path,
                "-D", "PY_RUNTIME=" + pythonRuntime] + parents
               + ["-p", profile, "/usr/bin/env"] + argv
    }

    static func environment(projectRoot: URL) throws -> [String: String] {
        let root = try physicalURL(projectRoot)
        let home = root.appendingPathComponent(".miniagent/isolated-home", isDirectory: true)
        let temp = root.appendingPathComponent(".miniagent/isolated-tmp", isDirectory: true)
        let cache = root.appendingPathComponent(".miniagent/isolated-cache", isDirectory: true)
        let fm = FileManager.default
        for dir in [home,temp,cache] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Never inherit the agent's API key, cloud tokens or arbitrary secrets
        // from the parent environment.
        let original = ProcessInfo.processInfo.environment
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                     "/usr/sbin", "/sbin"].joined(separator: ":")
        return [
            "PATH": paths,
            "HOME": home.path,
            "TMPDIR": temp.path + "/",
            "TMP": temp.path,
            "TEMP": temp.path,
            "XDG_CACHE_HOME": cache.path,
            "PIP_CACHE_DIR": cache.appendingPathComponent("pip").path,
            "npm_config_cache": cache.appendingPathComponent("npm").path,
            "CARGO_HOME": cache.appendingPathComponent("cargo").path,
            "RUSTUP_HOME": cache.appendingPathComponent("rustup").path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
            "LANG": original["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "DEVELOPER_DIR": original["DEVELOPER_DIR"] ?? "",
            "SDKROOT": original["SDKROOT"] ?? "",
            "CLANG_MODULE_CACHE_PATH": cache.appendingPathComponent("clang-modules").path
        ]
    }
}
