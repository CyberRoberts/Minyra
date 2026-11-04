import SwiftUI
import AppKit

struct MiniCompanionOverlay: View {
    @EnvironmentObject private var agent: AgentCore
    @StateObject private var miniAI = MiniCompanionAI()
    @State private var expanded = false
    @State private var showMiniSettings = false
    @State private var draft = ""
    @State private var savedOffset = CGSize.zero
    @State private var chatWidth: CGFloat = 330
    @State private var chatHeight: CGFloat = 385
    @State private var avatarWidth: CGFloat = 146
    private let purple = Color(red: 0.75, green: 0.54, blue: 0.98)

    var body: some View {
        GeometryReader { geometry in
            let avatar = avatarWidth
            let avatarHeight = avatar * 1.26
            let panelWidth = expanded ? visibleChatWidth(geometry.size) : avatar + 10
            let panelHeight = avatarHeight + (expanded ? visibleChatHeight(geometry.size) + 8 : 0)
            VStack(alignment: .trailing, spacing: expanded ? 8 : 0) {
                if expanded {
                    chatBubble
                        .frame(width: visibleChatWidth(geometry.size),
                               height: visibleChatHeight(geometry.size))
                        .overlay(alignment: .bottomTrailing) {
                            resizeChatHandle
                        }
                }
                avatarView(avatar, area: geometry.size,
                           panel: CGSize(width: panelWidth, height: panelHeight))
                    .frame(width: avatar, height: avatarHeight)
            }
            .frame(width: panelWidth, height: panelHeight, alignment: .bottomTrailing)
            .position(anchoredPosition(in: geometry.size,
                                       content: CGSize(width: panelWidth, height: panelHeight)))
            .onAppear {
                let d = UserDefaults.standard
                let a = d.double(forKey: "miniAvatarWidth")
                let w = d.double(forKey: "miniChatWindowWidth")
                let h = d.double(forKey: "miniChatWindowHeight")
                if a >= 96 && a <= 260 { avatarWidth = CGFloat(a) }
                if w >= 280 && w <= 650 { chatWidth = CGFloat(w) }
                if h >= 220 && h <= 700 { chatHeight = CGFloat(h) }
                savedOffset = CGSize(width: d.double(forKey: "miniAvatarOffsetX"),
                                     height: d.double(forKey: "miniAvatarOffsetY"))
                miniAI.refreshConfiguration()
            }
        }
        .sheet(isPresented: $showMiniSettings) {
            MiniChatSettingsView(onSaved: { miniAI.refreshConfiguration() })
        }
    }


    private func visibleChatWidth(_ area: CGSize) -> CGFloat {
        min(max(250, area.width - 20), max(280, chatWidth))
    }
    private func visibleChatHeight(_ area: CGSize) -> CGFloat {
        let limit = max(205, area.height - avatarWidth * 1.26 - 26)
        return min(limit, max(220, chatHeight))
    }

    private func anchoredPosition(in area: CGSize, content: CGSize) -> CGPoint {
        let left = content.width / 2 + 5
        let right = max(left, area.width - content.width / 2 - 5)
        let top = content.height / 2 + 5
        let bottom = max(top, area.height - content.height / 2 - 5)
        let baseX = area.width - content.width / 2 - 12
        let baseY = area.height - content.height / 2 - 12
        return CGPoint(x: min(right, max(left, baseX + savedOffset.width)),
                       y: min(bottom, max(top, baseY + savedOffset.height)))
    }

    private func finishMoving(_ translation: CGSize, inside area: CGSize, panel: CGSize) {
        // Persist only realizable positions, rather than accumulating huge
        // off-screen offsets that later make the character "unresponsive".
        let centerX = area.width - panel.width / 2 - 12
        let centerY = area.height - panel.height / 2 - 12
        let x = MiniInteractionMath.bounded(centerX + savedOffset.width,
                                            delta: translation.width,
                                            minimum: panel.width / 2 + 5,
                                            maximum: max(panel.width / 2 + 5, area.width - panel.width / 2 - 5))
        let y = MiniInteractionMath.bounded(centerY + savedOffset.height,
                                            delta: translation.height,
                                            minimum: panel.height / 2 + 5,
                                            maximum: max(panel.height / 2 + 5, area.height - panel.height / 2 - 5))
        savedOffset = CGSize(width: x - centerX, height: y - centerY)
        UserDefaults.standard.set(Double(savedOffset.width), forKey: "miniAvatarOffsetX")
        UserDefaults.standard.set(Double(savedOffset.height), forKey: "miniAvatarOffsetY")
    }

    private func avatarView(_ width: CGFloat, area: CGSize, panel: CGSize) -> some View {
        MiniCharacterView(
            mood: characterMood,
            onTap: { expanded.toggle() },
            onMove: { delta in finishMoving(delta, inside: area, panel: panel) },
            onResize: { delta in
                avatarWidth = MiniInteractionMath.bounded(avatarWidth,
                             delta: delta, minimum: 96, maximum: 240)
                UserDefaults.standard.set(Double(avatarWidth), forKey: "miniAvatarWidth")
            }
        )
        .frame(width: width, height: width * 1.26)
        .background(Color.clear)
        .help("单击打开聊天；拖动移动；拖动右下角调整大小")
    }

    private var characterMood: String {
        if miniAI.answering { return "talk" }
        if agent.lifecycle == .completed { return "happy" }
        if agent.lifecycle == .blocked { return "think" }
        return agent.running ? "think" : "idle"
    }

    private var chatBubble: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("Mini 酱 · DeepSeek Chat ♡")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { showMiniSettings = true } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.plain).help("Mini 酱专用 DeepSeek 模型和 API 设置")
                Button { expanded = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
            Text("只是 AI 闲聊 · 不执行编程操作 · 按 API 用量计费")
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if miniAI.messages.isEmpty {
                            Text("嘿嘿，今天想聊点什么？♡")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        ForEach(miniAI.messages) { line in
                            Text((line.who == .user ? "你：" : "Mini：") + line.content)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(line.who == .user ? purple.opacity(0.16) : Color.white.opacity(0.06)))
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: miniAI.messages.count) { _ in
                    if let last = miniAI.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
            Text(miniAI.status)
                .font(.system(size: 10))
                .foregroundColor(miniAI.configured ? .secondary : .orange)
                .lineLimit(2)
            if !miniAI.configured {
                Button("设置 Mini 酱专用 DeepSeek") { showMiniSettings = true }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 6) {
                TextField("和 Mini 酱说点什么…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button { send() } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(!miniAI.configured || miniAI.answering ||
                          draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text("拖动右下角调整聊天窗口")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Spacer(minLength: 12)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(red: 0.20, green: 0.15, blue: 0.28)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(purple.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10)
    }

    private var resizeChatHandle: some View {
        MiniNativeChatResizeHandle { delta in
            chatWidth = MiniInteractionMath.bounded(chatWidth,
                        delta: delta.width, minimum: 280, maximum: 650)
            chatHeight = MiniInteractionMath.bounded(chatHeight,
                         delta: delta.height, minimum: 220, maximum: 700)
            UserDefaults.standard.set(Double(chatWidth), forKey: "miniChatWindowWidth")
            UserDefaults.standard.set(Double(chatHeight), forKey: "miniChatWindowHeight")
        }
        .frame(width: 28, height: 28)
        .padding(3)
        .help("拖动调整 Mini 酱聊天窗口宽度和高度")
    }
    private func send() {
        let message = draft
        guard miniAI.configured && !miniAI.answering else { return }
        draft = ""
        miniAI.send(message)
    }
}
