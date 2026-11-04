import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var agent: AgentCore
    @State private var draft = ""
    @State private var showSettings = false
    @State private var dragActive = false
    @State private var showCompanion = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
                .overlay(alignment: .bottomTrailing) {
                    if showCompanion { MiniCompanionOverlay() }
                }
            if agent.running || agent.paused { taskActivityBanner }
            statusBar
            Divider()
            composer
        }
        .background(Color(red: 0.14, green: 0.10, blue: 0.20))
        .preferredColorScheme(.dark)
        .onAppear { if !agent.configured { showSettings = true } }
        .sheet(isPresented: $showSettings) { APISettingsView(isOpen: $showSettings) }
        .onDrop(of: ["public.file-url"], isTargeted: $dragActive) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    var incoming: URL?
                    if let url = item as? URL { incoming = url }
                    else if let data = item as? Data { incoming = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let string = item as? String { incoming = URL(string: string) }
                    if let url = incoming, url.isFileURL {
                        DispatchQueue.main.async { agent.attachFiles([url]) }
                    }
                }
            }
            return !providers.isEmpty
        }
        .overlay(dragOverlay)
    }

    private var taskActivityBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: agent.running ? "arrow.triangle.2.circlepath" : "pause.circle")
            Text("当前：" + agent.progressDescription).lineLimit(1)
            if !agent.taskState.nextStep.isEmpty {
                Text("· 下一步：" + agent.taskState.nextStep)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
        }
        .font(.system(size: 11))
        .foregroundColor(Color(red: 0.72, green: 0.94, blue: 0.78))
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 12) {
            mascot(38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Minyra for Mac")
                    .font(.system(size: 17, weight: .semibold))
                Text("Mini 酱 · Native AI Coding Agent ♡")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
            Menu {
                Button("新建项目（自动建文件夹）") { agent.newProject() }
                    .disabled(agent.running)
                Button("打开已有项目") { agent.openExistingProject() }
                    .disabled(agent.running)
                Divider()
                Button("在 Finder 查看代码") { agent.openInFinder() }
            } label: {
                Label(agent.projectName, systemImage: "folder")
                    .lineLimit(1)
                    .font(.system(size: 12))
            }
            .frame(maxWidth: 190)
            Button { showCompanion.toggle() } label: {
                Image(systemName: showCompanion ? "person.crop.square.filled.and.at.rectangle" : "face.smiling")
                    .font(.system(size: 15))
            }
            .help(showCompanion ? "收起 Mini 酱陪伴气泡" : "显示 Mini 酱陪伴气泡")
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
            }
            .help("自己的 API 设置")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    private func mascot(_ dimension: CGFloat) -> some View {
        Group {
            if let image = NSImage(named: "MiniAgentIcon") {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else { Image(systemName: "sparkles").resizable().scaledToFit().padding(8) }
        }
        .frame(width: dimension, height: dimension)
        .cornerRadius(dimension * 0.25)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if agent.chat.count <= 1 { welcome }
                    ForEach(agent.chat) { item in
                        bubble(item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.chat.count) { _ in
                if let last = agent.chat.last { withAnimation(.easeOut(duration: 0.17)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                mascot(66)
                VStack(alignment: .leading, spacing: 5) {
                    Text("今天想做什么呢，喵～ ♡").font(.system(size: 19, weight: .semibold))
                    Text("不需要 VS Code 或手动建工程，直接告诉 Mini 酱就好～")
                        .font(.system(size: 12)).foregroundColor(.gray)
                }
            }
            Text("例：做一个 Mac 记账软件。把所有项目文件创建好，自动运行和检查错误。")
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.79, green: 0.72, blue: 0.95))
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func bubble(_ line: ChatLine) -> some View {
        let own = line.kind == .user
        return HStack(alignment: .top, spacing: 8) {
            if own { Spacer(minLength: 75) }
            if !own { mascot(26) }
            VStack(alignment: .leading, spacing: 6) {
                if !own { Text(line.kind == .error ? "遇到问题啦" : (line.kind == .progress ? "Mini 酱的工作记录" : "Mini 酱")).font(.system(size: 11, weight: .semibold)).foregroundColor(.gray) }
                Text(line.message)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14).fill(bubbleColor(line.kind)))
            .frame(maxWidth: own ? 570 : 720, alignment: .leading)
            if !own { Spacer(minLength: 25) }
        }
    }
    private func bubbleColor(_ kind: ChatLine.Kind) -> Color {
        switch kind {
        case .user: return Color(red: 0.39, green: 0.23, blue: 0.58)
        case .assistant: return Color(red: 0.17, green: 0.15, blue: 0.22)
        case .info: return Color(red: 0.15, green: 0.145, blue: 0.19)
        case .progress: return Color(red: 0.13, green: 0.19, blue: 0.19)
        case .error: return Color(red: 0.34, green: 0.18, blue: 0.23)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle().fill(agent.lifecycle == .completed ? Color.green : (agent.lifecycle == .blocked ? Color.orange : (agent.running ? Color.green : Color.gray))).frame(width: 7, height: 7)
            Text(agent.activity).lineLimit(1).help(agent.activity)
            Spacer(minLength: 8)
            Text(agent.waitingForAPI ? "等待 API 恢复" : agent.statusLabel)
            if !agent.queuedInstructions.isEmpty { Text("待处理补充 \(agent.queuedInstructions.count) 条") }
            Text(agent.routingStatus).lineLimit(1)
            Text("API \(agent.apiCalls) 次")
            Text(agent.tokensDescription)
            Text("操作 \(agent.toolOperations) 次")
        }
        .font(.system(size: 11))
        .foregroundColor(.gray)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(red: 0.13, green: 0.115, blue: 0.17))
    }

    private var composer: some View {
        VStack(spacing: 10) {
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .frame(height: 90)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color(red: 0.17, green: 0.15, blue: 0.22)))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.purple.opacity(0.3), lineWidth: 1))
            HStack(spacing: 10) {
                Button { agent.attachUsingPanel() } label: {
                    Label("添加文件", systemImage: "plus.circle.fill")
                }
                .help("附加现有项目文件、项目文件夹或 ZIP；也可以把它们拖进窗口")
                .disabled(agent.running)
                Spacer()
                if agent.running {
                    Button("暂停") { agent.stop() }
                        .buttonStyle(.bordered)
                } else if agent.paused {
                    Button("继续开发") { agent.continueWork() }
                        .buttonStyle(.bordered)
                        .disabled(!agent.configured)
                }
                Button(agent.running ? "补充要求" : "交给 Mini 酱") {
                    let message = draft
                    draft = ""
                    agent.start(message)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 12))
        }
        .padding(16)
    }
    private var dragOverlay: some View {
        Group {
            if dragActive {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.green.opacity(0.12))
                    .overlay(Text("松开文件，Mini 自动整理到当前项目").font(.headline))
                    .padding(9)
                    .allowsHitTesting(false)
            }
        }
    }
}

