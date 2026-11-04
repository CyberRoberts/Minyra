import Foundation

// Deterministic, local routing: choosing a model never incurs an extra API request.
// For non-DeepSeek providers, use the user's chosen model unless BOTH custom model IDs are supplied.
enum MiniDifficulty: String { case simple, normal, complex }

struct MiniRoute: Equatable {
    let model: String
    let effort: String?           // nil = don't send provider-specific reasoning parameters
    let maxTokens: Int
    let role: String
    let difficulty: MiniDifficulty
    var display: String { "\(model) · \(role)" }
}

enum MiniModelRouter {
    static func isDeepSeek(_ base: String) -> Bool {
        guard let host = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "api.deepseek.com" || host.hasSuffix(".deepseek.com")
    }

    static func difficulty(_ text: String) -> MiniDifficulty {
        let q = text.lowercased()
        let high = ["完整网站", "完整应用", "完整软件", "全栈", "架构设计", "架构", "数据库", "后端", "部署", "重构", "多模块", "多平台", "跨平台", "集成", "迁移", "从零", "端到端", "复杂", "full stack", "architecture", "refactor", "migration", "database", "production"]
        let medium = ["开发", "修复", "实现", "构建", "测试", "页面", "项目", "程序", "功能", "接口", "api", "create", "build", "debug", "feature", "fix", "code"]
        let weight = high.filter { q.contains($0) }.count
        if weight >= 2 || (weight >= 1 && q.count >= 80) { return .complex }
        if weight >= 1 || medium.contains(where: { q.contains($0) }) { return .normal }
        return .simple
    }

    static func supportsRouting(baseURL: String, auto: Bool, fast: String, strong: String) -> Bool {
        auto && (isDeepSeek(baseURL) || (!fast.isEmpty && !strong.isEmpty))
    }

    static func choose(baseURL: String, configured: String, auto: Bool, fast: String,
                       strong: String, goal: String, phase: String = "", failures: Int = 0,
                       specialist: String? = nil) -> MiniRoute {
        let d = difficulty(goal)
        guard supportsRouting(baseURL: baseURL, auto: auto, fast: fast, strong: strong) else {
            return MiniRoute(model: configured, effort: nil, maxTokens: specialist == nil ? 6500 : 1800,
                             role: specialist ?? "单模型执行", difficulty: d)
        }
        let deepSeek = isDeepSeek(baseURL)
        let fastID = fast.isEmpty ? "deepseek-flash" : fast
        let strongID = strong.isEmpty ? "deepseek-v4-pro" : strong
        if specialist == "架构" {
            return MiniRoute(model: strongID, effort: deepSeek ? "low" : nil, maxTokens: 2500,
                             role: "架构子 Agent", difficulty: .complex)
        }
        if specialist == "诊断" {
            return MiniRoute(model: strongID, effort: deepSeek ? "high" : nil, maxTokens: 4200,
                             role: "诊断子 Agent", difficulty: .complex)
        }
        if failures >= 2 {
            return MiniRoute(model: strongID, effort: deepSeek ? "high" : nil, maxTokens: 7000,
                             role: "疑难修复", difficulty: .complex)
        }
        if d == .simple {
            return MiniRoute(model: fastID, effort: deepSeek ? "none" : nil, maxTokens: 3400,
                             role: "快速执行", difficulty: d)
        }
        // Implementation/tool calls stay cheap even when the top-level project is complex.
        return MiniRoute(model: fastID, effort: deepSeek ? "none" : nil,
                         maxTokens: 5800, role: "代码执行", difficulty: d)
    }
}
