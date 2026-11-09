// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native conversation detail.

import PhoneDSHAgentCore
import PhoneDSH
import ProbeKit
import PhoneDSHEngine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ChatPage: View {
    var openDrawer: (() -> Void)? = nil
    var drawerExpanded: Bool = false
    /// Optional deep entry used by the preview router/debug route.
    var initialPreviewTarget: PreviewTarget? = nil
    #if DEBUG
    /// 预览专用:直接吃一份本地造好的消息,不订阅宿主、不等记录就绪。
    var previewItems: [ChatItem]? = nil
    /// 预览专用:进页面时输入框里已经有这段字(验超长文本用)。
    var previewDraft: String? = nil
    #endif

    @State private var model = ChatModel.shared
    @State private var voice = ComposerVoiceInput()
    @State private var showDeviceConnections = false
    @State private var deviceCoordinator = DeviceSessionCoordinator.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var management = DSHManagementModel.shared
    @State private var draft = ""
    #if DEBUG
    @State private var didInjectDebugState = false
    @State private var hitProbe = ""
    #endif
    @State private var previousSessionKey = ""
    @AppStorage("chat.drafts.v1") private var savedDrafts = "{}"
    private var busyEnterMode: String { preferences.busyEnterMode }
    /// Official default is completion-time folding; the `On next message`
    /// option is the iOS adaptation exposed in the header `...` menu.
    @State private var preferences = NativeChatPreferences.shared
    private var collapseOnNextMessage: Bool { preferences.collapseTiming == .nextInput }
    private var collapseTimingBinding: Binding<Bool> {
        Binding(get: { preferences.collapseTiming == .nextInput },
                set: { preferences.setCollapseTiming($0 ? .nextInput : .completion) })
    }
    /// The composer's own responder owns focus: a `UITextView` wrapper is the
    /// only way to hand the software keyboard a 发送 return key and to
    /// intercept Return before it inserts a newline.
    @State private var inputFocused = false
    /// Restore the keyboard after a command-result sheet closes if the
    /// composer had focus when the command was submitted.
    @State private var restoreComposerFocus = false
    @State private var pendingAttachments: [HarnessAttachment] = []
    @State private var showAttachmentPicker = false
    /// "添加文件" imports into the workspace; images stay native attachments.
    @State private var showFileImport = false
    /// Status line for a workspace import (the agent reads the file by path).
    @State private var fileImportNotice: String?
    @State private var commandExecution: NativeCommandExecution?
    @State private var showCommandResult = false
    @State private var isExecutingCommand = false
    /// One composer notice (official `InputBar` notice channel): command
    /// settlement and refusals land here instead of a silent banner.
    @State private var composerNotice: ComposerNotice?
    /// Highlighted row of the slash-command menu (`↑`/`↓`, `Tab`/`Enter`).
    @State private var slashHighlight = 0
    /// Esc closes the menu without deleting the typed token; the next edit
    /// re-opens it (official `dismissPopup` keeps the draft).
    @State private var slashMenuDismissed = false
    /// Measured height of the composer's editable surface (36…336).
    @State private var composerHeight: CGFloat = 36
    /// The command currently in flight, so `/compact` can say 正在压缩…
    @State private var executingCommandName: String?
    @State private var showSessions = false
    @State private var showWorkbench = false
    @State private var initialWorkbenchPath: String?
    @State private var previewTarget: PreviewTarget?
    @State private var showSettings = false
    @State private var showProviderSettings = false
    /// A path whose bytes had not arrived yet; the next file refresh retries it.
    @State private var pendingPreviewPath: String?
    @State private var showSessionList = false
    @State private var debugSheet: String?
    @State private var showConfiguration = false
    @State private var showActivity = false
    @State private var showSubagentCatalog = false
    @State private var showJobList = false
    @State private var showArtifacts = false
    @State private var showScheduleList = false
    @State private var previewPlan: NativePlanPreview?
    @State private var foldedTurns: Set<Int> = []
    @State private var autoFoldedTurns: Set<Int> = []
    /// Turns the person opened by hand: a later auto-fold must never close
    /// one of them again, in either folding-timing mode.
    @State private var manuallyExpandedTurns: Set<Int> = []
    @State private var tailUsage: NativeTurnUsage?
    @State private var copiedTurn: Int?
    @State private var queue = ComposerQueueStore()
    @State private var queueExpanded = false
    @State private var queueEditItem: ComposerQueue.Item?
    @State private var queueEditText = ""
    /// The queue row whose edit/remove/steer RPC is in flight; every queue
    /// action is disabled while it runs (official `busy` in `QueueDock`).
    @State private var queueActionBusyID: String?
    @State private var showRuntimeDetails = false
    @State private var showSessionSettings = false
    @State private var cardsExpanded = false
    @State private var keyboardVisible = false
    @State private var renameTarget: ManagedSession?
    @State private var renameText = ""

    private func beginRename() {
        guard let id = model.currentSessionID,
              let session = management.sessions.first(where: { $0.id == id }) else { return }
        renameText = session.title
        renameTarget = session
    }
    @State private var confirmAccessMode: NativeAccessMode?
    @State private var isSelectingAccessMode = false
    @State private var attachmentError: String?
    @State private var nearBottom = true
    /// Measured transcript height; the scroll helpers use it to refuse a
    /// scroll into empty space.
    @State private var transcriptContentHeight: CGFloat = 0
    /// Set when a session opens; the next transcript layout jumps to the tail
    /// without animation so history loading never leaves the view at the top.
    @State private var pendingInitialScroll = false
    @State private var userScrolledAway = false
    /// The finger is on the transcript (or it is still coasting from a
    /// flick). Only this may switch following off: content growth alone
    /// never means the person scrolled away. iOS 18+ reports it.
    @State private var userScrolling = false
    @State private var tracksScrollPhase = false
    /// Last measured tail offset, kept outside `@State`: it changes on every
    /// scroll frame and only feeds the diagnostic line, so it must not
    /// invalidate the transcript view.
    private let scrollTrace = ScrollTraceBox()
    @State private var lastScrollTrace = Date.distantPast
    @State private var pasteLimitNoticed = false
    @State private var stopping = false
    @State private var scrollToLatestTrigger = 0
    /// Coalesces follow-the-tail scrolls so one lands after the lazy stack
    /// has laid the new rows out (see `scheduleTailScroll`).
    @State private var tailScrollTask: Task<Void, Never>?
    @State private var loadingEarlierTranscript = false

    private var providerNeedsKey: Bool {
        guard let profile = (try? PhoneModelProviderSettings.shared.load())?.selected else { return true }
        guard let status = try? PhoneModelProviderSettings.shared.apiKeyStatus(for: profile.id) else { return true }
        return status != .present
    }

    private var sessionKey: String { model.currentSessionID ?? "new" }
    private var sessionTitle: String {
        guard let id = model.currentSessionID else { return "新会话" }
        let title = management.sessions.first(where: { $0.id == id })?.title ?? ""
        if title.isEmpty || ["new conversation", "conversation"].contains(title.lowercased()) {
            return model.items.contains(where: { $0.kind == .user }) ? "当前会话" : "新会话"
        }
        return title
    }
    private var visibleItems: [ChatItem] {
        #if DEBUG
        if let previewItems { return previewItems }
        #endif
        return model.items.filter { $0.kind != .status }
    }
    /// A running turn or a live subagent/background job puts a small spinner
    /// on the consolidated settings button.
    private var headerActivityRunning: Bool {
        if model.turnRunning { return true }
        if subagentEntries.contains(where: { $0.activity == .running }) { return true }
        return management.jobs.contains { ($0.status ?? "").lowercased() == "running" }
    }

    /// Official `subagentCatalog` projection → the header catalog view model.
    /// Running state comes from the session list row (`running`), because the
    /// catalog itself only carries identity/label/mode.
    private var subagentEntries: [NativeSubagentCatalogEntry] {
        (model.projectedSubagents?.arrayValue ?? []).compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            let mode = NativeSubagentMode(rawValue: row["mode"]?.stringValue ?? "") ?? .unknown
            let running = management.sessions.first(where: { $0.id == id })?.running == true
            return NativeSubagentCatalogEntry(
                id: id,
                label: row["label"]?.stringValue,
                mode: mode,
                activity: running ? .running : .inactive,
                parentID: row["parentSessionId"]?.stringValue,
                children: [])
        }
    }

    private var transcriptScrollSignature: String {
        "\(visibleItems.map(\.id).joined(separator: ","))|\(visibleItems.last?.text ?? "")"
    }
    /// 首页页头(HomeSpec):不画底条,浮在页面上。左边 44 圆按钮开会话列表,
    /// 标题块从 x 76 起(16 + 44 + 16),右边 92×44 胶囊放新建对话和更多。
    private var chatHeader: some View {
        HStack(spacing: 0) {
            Button {
                openDrawer?()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().frame(width: 18, height: 2.4)
                    Capsule().frame(width: 12, height: 2.4)
                }
                .foregroundStyle(HomeSpec.primaryButton)
                .frame(width: HomeSpec.navButton, height: HomeSpec.navButton)
                .background(HomeSpec.surface, in: Circle())
                .homeFloatingShadow()
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开会话列表")

            Button { beginRename() } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(sessionTitle)
                        .font(.system(size: HomeSpec.navTitleSize, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .frame(height: HomeSpec.navTitleLine)
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .regular))
                            .frame(width: 16, height: 16)
                        Text(projectSubtitle)
                            .font(.system(size: HomeSpec.navSubtitleSize))
                    }
                    .foregroundStyle(HomeSpec.textSubtle)
                    .frame(height: HomeSpec.navSubtitleLine)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.currentSessionID == nil)
            .accessibilityIdentifier("chat.session-title")
            .accessibilityHint("点按重命名会话")
            .padding(.horizontal, 16)

            HeaderActionPill(hasOnlineDevices: deviceCoordinator.hasOnlineDevices,
                             connectIdentifier: "chat.connect-device",
                             menuIdentifier: nil,
                             showsMenuActivityDot: headerActivityRunning,
                             onConnect: { showDeviceConnections = true }) {
                chatHeaderMenuItems
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, HomeSpec.navTop)
        .frame(height: HomeSpec.navTop + HomeSpec.navButton)
    }

    /// 副标题是会话所属的文件夹。每个会话都有文件夹:不在任何文件夹里的就算在默认的「手机工作区」。
    private var projectSubtitle: String {
        guard let id = model.currentSessionID,
              let workspace = management.workspaces.first(where: { $0.sessionIDs.contains(id) })
        else { return DrawerTitles.defaultFolderName }
        return DrawerTitles.workspaceTitle(workspace.title, index: 1)
    }

    @ViewBuilder
    private var chatHeaderMenuItems: some View {
        if !subagentEntries.isEmpty {
            Button("子智能体（\(subagentEntries.count)）", systemImage: "person.2") {
                showSubagentCatalog = true
            }
        }
        if !management.jobs.isEmpty {
            Button("后台任务（\(management.jobs.count)）", systemImage: "list.bullet") {
                showJobList = true
            }
        }
        if !management.scheduleRecords.isEmpty {
            Button("定时任务（\(management.scheduleRecords.count)）", systemImage: "calendar.badge.clock") {
                showScheduleList = true
            }
        }
        Button("产物", systemImage: "shippingbox") {
            showArtifacts = true
        }
        if model.currentSessionID != nil {
            Button("工作区", systemImage: "folder") {
                showWorkbench = true
            }
        }
        Divider()
        ShareLink(item: historyExport,
                  subject: Text("对话记录"),
                  preview: SharePreview("对话记录")) {
            Label("导出对话记录", systemImage: "square.and.arrow.up")
        }
        Button("运行状态", systemImage: "waveform.path.ecg") { showRuntimeDetails = true }
        Button("插件与工具", systemImage: "puzzlepiece.extension") { showSessionSettings = true }
        if let preset = model.agentPresetLabel {
            Divider()
            Text("Agent 预设：\(preset)")
        }
        Divider()
        // Official `On next message` collapse timing, as a menu
        // pair on the phone (no DSH settings page here).
        Picker("折叠时机", selection: collapseTimingBinding) {
            Text("完成时").tag(false)
            Text("下一条消息").tag(true)
        }
    }

    private var latestToolFailure: ChatItem? {
        guard let lastResult = model.items.last(where: { item in
            if case .toolResult = item.kind { return true }
            return false
        }), case .toolResult(isError: true) = lastResult.kind else { return nil }
        return lastResult
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            // A failure that belongs to one message is rendered under it; every
            // other failure (send refused, session open, stream error) needed a
            // surface too — it used to be invisible on this page.
            if model.failedItemID == nil, let error = model.userFacingError {
                errorBanner(error)
            }
            if let error = model.commandsError { commandErrorBanner(error) }
            cardsRegion
            transcript
        }
        // The composer is a bottom safe-area inset, not a stack item: the
        // keyboard then lifts only the composer and the content area shrinks
        // from the bottom. Putting it in the VStack lets the keyboard push the
        // whole stack (including the title row) up under the status bar on
        // newer iOS versions.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let question = model.pendingQuestion {
                questionTakeover(question)
            } else {
                composer
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
            cardsExpanded = false
        }
        .background(HomeSpec.page)
        .navigationTitle({
            #if DEBUG
            return hitProbe
            #else
            return ""
            #endif
        }())
        .navigationBarTitleDisplayMode(.inline)
        // 系统导航栏整个隐掉:页头自己画、自己接点击。留着那层,看得见的是
        // 我们的页头,接点击的却是它,左上角那个按钮就是这么点不开的。
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // The keyboard's own 发送 key replaced the custom toolbar: the
        // composer text view sets `returnKeyType = .send` and intercepts
        // Return, so a second button above the keyboard would be the only
        // send affordance that is *not* what the web bar does.
        .alert("重命名会话", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                guard let session = renameTarget else { return }
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renameTarget = nil
                guard !title.isEmpty else { return }
                Task { await management.rename(session, to: title) }
            }
        }
        .sheet(isPresented: $showDeviceConnections) {
            NavigationStack { NativeDeviceConnectionPage() }.homeSheetChrome()
        }
        .onDisappear { voice.cancel(); voice.stopSpeaking() }
        .sheet(isPresented: $showSessions) {
            SessionsPage { showSessions = false }
                .presentationDetents([.large])
                .homeSheetChrome()
        }
        .sheet(isPresented: $showWorkbench) {
            NativeWorkbenchPage(sessionID: model.currentSessionID, initialPath: initialWorkbenchPath)
                .homeSheetChrome()
        }
        .fullScreenCover(item: $previewTarget) { target in
            NavigationStack {
                PreviewSurface(target: target)
            }
        }
        .sheet(item: Binding(get: { debugSheet.map(DebugSheetToken.init) }, set: { debugSheet = $0?.value })) { token in
            if token.value == "provider" {
                NavigationStack { ModelProviderSettingsPage().homeSheetDone() }
            }
        }
        .sheet(isPresented: $showProviderSettings) {
            NavigationStack { ModelProviderSettingsPage().homeSheetDone() }
                .homeSheetChrome()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsPage(onOpenSession: { showSettings = false }) }
                .homeSheetChrome()
        }
        .sheet(isPresented: $showSessionSettings) {
            NavigationStack { NativeConfigurationPage(presentedAsSheet: true) }
                .homeSheetChrome()
        }
        .sheet(isPresented: $showConfiguration) {
            NavigationStack { NativeConfigurationPage(presentedAsSheet: true) }
                .homeSheetChrome()
        }
        .sheet(isPresented: $showCommandResult) {
            if let commandExecution {
                CommandExecutionResultPage(execution: commandExecution,
                                           onOpenFile: openWorkspaceResult)
                    .homeSheetChrome()
            }
        }
        .sheet(isPresented: $showRuntimeDetails) {
            NavigationStack { RuntimeDetailsPage(model: model).homeSheetDone() }
                .homeSheetChrome()
        }
        .sheet(isPresented: $showSubagentCatalog) {
            VStack(spacing: 0) {
                NativeSubagentCatalogSheet(
                    entries: subagentEntries,
                    currentSessionID: model.currentSessionID,
                    availableSize: CGSize(width: UIScreen.main.bounds.width,
                                          height: UIScreen.main.bounds.height - 120),
                    onOpenSession: { entry in
                        showSubagentCatalog = false
                        Task { await model.selectSession(entry.id) }
                    })
                    .padding(.horizontal, HomeSpec.chromeInset)
                    .padding(.top, 20)
                Spacer(minLength: 0)
            }
            .background(HomeSpec.page)
            .presentationDetents([.medium, .large])
            .homeSheetChrome()
        }
        .sheet(isPresented: $showJobList) {
            NativeJobListSheet(jobs: management.jobs) {
                guard let id = model.currentSessionID else { return }
                Task { await management.refreshActivity(sessionID: id) }
            }
            .presentationDetents([.medium, .large])
            .homeSheetChrome()
        }
        .sheet(isPresented: $showScheduleList) {
            NativeScheduleListSheet(schedules: management.scheduleRecords) {
                guard let id = model.currentSessionID else { return }
                Task { await management.refreshActivity(sessionID: id) }
            }
            .presentationDetents([.medium, .large])
            .homeSheetChrome()
        }
        .sheet(isPresented: $showArtifacts) {
            if let sessionID = model.currentSessionID {
                NavigationStack { SessionArtifactsPage(sessionID: sessionID) }
                    .presentationDetents([.medium, .large])
                    .homeSheetChrome()
            }
        }
        .sheet(item: $previewPlan) { plan in
            NavigationStack {
                ScrollView {
                    NativeMarkdownBody(markdown: plan.markdown, streaming: false,
                                       workspaceFiles: model.files, onOpenFile: openWorkspaceResult)
                        .font(NativeChatTheme.bodyFont())
                        .lineSpacing(NativeChatTheme.bodyLineSpacing)
                        .padding(NativeParityTokens.transcriptSide)
                }
                .navigationTitle(plan.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { previewPlan = nil }.fontWeight(.semibold)
                    }
                }
            }
            .homeSheetChrome()
        }
        // 「完全权限」是唯一会改掉未来的开关:点它不直接生效,先弹系统的确认窗。
        // 标题里的名字和菜单项一字不差;开着的时候点同一项不用再问。
        .alert(accessModeConfirmationTitle, isPresented: Binding(
            get: { confirmAccessMode != nil },
            set: { if !$0 { confirmAccessMode = nil } }
        )) {
            Button("取消", role: .cancel) { confirmAccessMode = nil }
            Button("开启") {
                guard let mode = confirmAccessMode else { return }
                Task { await selectAccessMode(mode) }
                confirmAccessMode = nil
            }
        } message: {
            Text(AccessModeWording.confirmationMessage(for: confirmAccessMode?.id ?? "")
                 ?? "之后改文件、跑命令都不再问你。")
        }
        // 系统窗里的按钮吃这层的 tint,不写就是黑的,不是我们的蓝。
        .tint(ChatPage.accent)
        .sheet(isPresented: $showActivity) {
            if let sessionID = model.currentSessionID {
                NavigationStack { SessionActivityPage(sessionID: sessionID) }
                    .homeSheetChrome()
            }
        }
        .fileImporter(
            isPresented: $showAttachmentPicker,
            allowedContentTypes: Self.imageContentTypes,
            allowsMultipleSelection: true,
            onCompletion: loadAttachments
        )
        // DSH's prompt path accepts image attachments only; any other file is
        // imported into the session workspace (the DSH-native way for the
        // agent to read it) and inserted as a path reference.
        .fileImporter(
            isPresented: $showFileImport,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: loadWorkspaceFiles
        )
        .onChange(of: model.isTranscriptReady) { _, _ in
            #if DEBUG
            debugInjectIfReady()
            #endif
        }
        .onAppear {
            if let initialPreviewTarget, previewTarget == nil {
                previewTarget = initialPreviewTarget
            }
            #if DEBUG
            if debugChatState != nil { debugInjectIfReady() }
            #endif
            previousSessionKey = sessionKey
            draft = savedDraft(for: sessionKey)
            #if DEBUG
            // 预览:输入框里先放好那段超长文本,验行高和滚动。
            if let previewDraft, draft.isEmpty { draft = previewDraft }
            #endif
            if model.isStarted { Task { await management.refresh() } }
            // The native surface owns the one host now, so a cold launch
            // starts it directly instead of waiting for a tap. `autoRecover`
            // lets a persisted `Failed` controller (D14) be acknowledged once
            // at launch, so reopening the App is enough to get a working
            // engine back.
            if !model.isStarted, !model.busy {
                #if DEBUG
                if previewItems == nil && PreviewScreen.requested == nil {
                    Task { await model.start(autoRecover: true) }
                }
                #else
                Task { await model.start(autoRecover: true) }
                #endif
            }
            // Device-test automation (PDSH_CHAT_AUTOSTART / PDSH_CHAT_AUTOPROMPT).
            model.autostartIfRequested()
#if DEBUG
            // A deterministic composer draft for screenshot passes
            // (`PDSH_DEBUG_DRAFT=/c` renders the command menu without typing).
            if let seeded = ProcessInfo.processInfo.environment["PDSH_DEBUG_DRAFT"], draft.isEmpty {
                draft = seeded
            }
            if ProcessInfo.processInfo.environment["PDSH_DEBUG_TOOLRUN"] == "1", model.items.isEmpty {
                model.debugInjectToolRun()
            }
            if ProcessInfo.processInfo.environment["PDSH_DEBUG_START"] == "1" {
                Task { @MainActor in
                    await model.start()
                    try? await Task.sleep(for: .milliseconds(600))
                    if ProcessInfo.processInfo.environment["PDSH_DEBUG_FOCUS"] == "1" {
                        inputFocused = true
                    }
                }
            } else if ProcessInfo.processInfo.environment["PDSH_DEBUG_FOCUS"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    inputFocused = true
                }
            }
            if let sheet = ProcessInfo.processInfo.environment["PDSH_DEBUG_SHEET"], !sheet.isEmpty {
                let delay = Int(ProcessInfo.processInfo.environment["PDSH_DEBUG_SHEET_DELAY_MS"] ?? "") ?? 400
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delay))
                    switch sheet {
                    case "settings": showSettings = true
                    case "sessions": showSessions = true
                    case "provider": debugSheet = "provider"
                    case "config": showConfiguration = true
                    case "workbench": showWorkbench = true
                    default: break
                    }
                }
            }
#endif
        }
        .onChange(of: model.currentSessionID) { _, _ in
            // A successful selection can update ChatModel from the sidebar's
            // async task before its completion callback reaches this sheet.
            // Close from the observed source of truth as well, so restoring a
            // real session never leaves the user stranded in the sidebar.
            showSessions = false
            foldedTurns = []
            autoFoldedTurns = []
            manuallyExpandedTurns = []
            persistDraft(draft, for: previousSessionKey)
            previousSessionKey = sessionKey
            draft = savedDraft(for: sessionKey)
            #if DEBUG
            // 预览:输入框里先放好那段超长文本,验行高和滚动。
            if let previewDraft, draft.isEmpty { draft = previewDraft }
            #endif
            pendingAttachments.removeAll()
            attachmentError = nil
            // Opening another session must show its newest message, not the
            // top of the transcript.
            nearBottom = true
            userScrolledAway = false
            pendingInitialScroll = true
            Task { await management.refresh() }
        }
        .onChange(of: draft) { _, value in persistDraft(value, for: sessionKey) }
        // Folding timing. `false` keeps the official completion-time default:
        // every eligible closed Turn folds as soon as it ends. `true` is the
        // iOS adaptation of `On next message`: a closed Turn folds only after
        // a later user/steering/trigger input exists, so the latest exchange
        // stays open. Either way a manual expand is remembered and never
        // overridden by a later auto-fold.
        .onChange(of: model.turnEndReasons) { _, _ in
            autoFoldClosedTurns()
        }
        .onChange(of: collapseOnNextMessage) { _, _ in
            autoFoldClosedTurns()
        }
        .onChange(of: inputRowSignature) { _, _ in
            guard collapseOnNextMessage else { return }
            autoFoldClosedTurns()
        }
        .onChange(of: showWorkbench) { _, isPresented in
            if !isPresented { initialWorkbenchPath = nil }
        }
        // A tool-written file lands in the materialized workspace a moment
        // after the result row; keep the list warm while a turn runs and open
        // a path the person already tapped as soon as it appears.
        .onChange(of: model.files) { _, files in
            guard let pending = pendingPreviewPath else { return }
            guard let match = files.first(where: { $0.relativePath == pending })
                ?? Self.uniqueBasenameMatch(pending, in: files) else { return }
            pendingPreviewPath = nil
            attachmentError = nil
            previewTarget = .workspaceFile(match.relativePath)
        }
        .task(id: model.currentSessionID) {
            guard let id = model.currentSessionID else {
                queue.prepare(for: nil)
                return
            }
            queue.prepare(for: id)
            await management.refreshActivity(sessionID: id)
            await model.refreshAgentPresetNames()
        }
        // Re-read the durable queue after session open, Worker ready/restart,
        // stream resync, a successful send, any inbox splice and every turn
        // boundary. This is the event-driven half of I-2.
        .task(id: queueRefreshKey) {
            await refreshComposerQueue(debounced: true)
        }
        .task(id: model.turnRunning) {
            guard model.turnRunning else { return }
            while !Task.isCancelled, model.turnRunning {
                model.refreshFiles()
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, model.turnRunning else { return }
                // Polling covers a claim/removal splice that maps to no event
                // kind (the second half of I-2, matching Android's 2 s poll).
                await refreshComposerQueue()
            }
        }
    }

    /// Home rhythm (HomeSpec): 16pt after a user bubble, 20pt between every
    /// other transcript block (process rows, answers, cards, the action row).
    static func spacing(before index: Int, in rows: [NativeTranscriptRow]) -> CGFloat {
        guard index > 0, index < rows.count else { return 0 }
        if case .item(let previous) = rows[index - 1], previous.kind == .user {
            return HomeSpec.paragraphGap
        }
        return HomeSpec.blockGap
    }

    /// Reasoning, tool calls and tool results share one process-group row.
    private static func isProcessKind(_ kind: ChatItem.Kind) -> Bool {
        switch kind {
        case .reasoning, .toolCall, .toolResult: return true
        default: return false
        }
    }

    private var timelineRows: [NativeTranscriptRow] {
        var rows: [NativeTranscriptRow] = []
        var lastTurn: Int?
        var pendingTurnControl: Int?
        let answerIDs: [Int: String] = Dictionary(
            grouping: visibleItems.filter { $0.turn != nil && $0.kind == .assistant },
            by: { $0.turn! }).compactMapValues { $0.last?.id }
        let rowItems = visibleItems.filter { item in
            guard let turn = item.turn, foldedTurns.contains(turn),
                  let answerID = answerIDs[turn] else { return true }
            if item.kind == .user || item.kind == .context { return true }
            return item.id == answerID
        }
        for item in rowItems {
            // A new prompt closes the previous Turn's tail above itself. User
            // rows often carry no turn number, so waiting for the next Turn's
            // first answer row would drop that tail under the new bubble.
            if item.kind == .user, let previous = lastTurn, item.turn != previous,
               let state = model.turnProcessState(for: previous), state != .running {
                rows.append(.turnTail(previous))
                lastTurn = nil
            }
            if let turn = item.turn, turn != lastTurn {
                if let previous = lastTurn, previous != turn,
                   model.turnProcessState(for: previous) != nil {
                    rows.append(.turnTail(previous))
                }
                lastTurn = turn
                pendingTurnControl = model.turnProcessState(for: turn) != nil ? turn : nil
            }
            // The official control row sits after the Turn's input and before
            // its process (controlAnchorSeq - 0.1), so defer it past user /
            // trigger rows instead of placing it above the prompt.
            if let pending = pendingTurnControl,
               item.kind != .user, item.kind != .context {
                rows.append(.turnProcess(pending))
                pendingTurnControl = nil
            }
            if item.kind == .context {
                if case .contexts(let previous)? = rows.last {
                    rows[rows.count - 1] = .contexts(previous + [item])
                } else {
                    rows.append(.contexts([item]))
                }
            } else if Self.isProcessKind(item.kind) {
                // A turn's reasoning/tool activity is process, not content: one
                // row for the whole run, opened on demand.
                if case .tools(let previous)? = rows.last {
                    rows[rows.count - 1] = .tools(previous + [item])
                } else {
                    rows.append(.tools([item]))
                }
            } else {
                rows.append(.item(item))
            }
        }
        if let lastTurn, model.turnProcessState(for: lastTurn) != nil {
            rows.append(.turnTail(lastTurn))
        }
        return rows
    }

    /// Official turn-tail: the action row is anchored after every content and
    /// process row of the Turn, independent of which assistant message closes it.
    @ViewBuilder
    private func turnTailRow(_ turn: Int) -> some View {
        let closing = visibleItems.last { $0.turn == turn && $0.kind == .assistant }
        let text = visibleItems.filter { $0.turn == turn && $0.kind == .assistant }
            .map(\.text).joined(separator: "\n\n")
        let usage = NativeTranscriptProjector.usage(forTurn: turn, in: visibleItems)
        if let closing {
            NativeTurnTail(
                time: model.turnEndTimes[turn] ?? closing.timestamp,
                isCopied: copiedTurn == turn,
                isBranchAvailable: false,
                showsUsage: usage != nil,
                onCopy: {
                    UIPasteboard.general.string = text
                    copiedTurn = turn
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        if copiedTurn == turn { copiedTurn = nil }
                    }
                },
                onFeedback: { feedback in
                    guard let messageID = closing.messageID else { return }
                    Task { _ = await model.rateMessage(messageID, positive: feedback == .like) }
                },
                onUsage: { tailUsage = usage })
                .sheet(isPresented: Binding(
                    get: { tailUsage != nil },
                    set: { if !$0 { tailUsage = nil } }
                )) {
                    if let usage = tailUsage { NativeTurnUsageDetails(usage: usage) }
                }
        }
    }

    /// A closed Turn is foldable only when it has both a final answer and at
    /// least one process row that would be hidden.
    private func turnHasProcess(_ turn: Int) -> Bool {
        guard let answerID = visibleItems.last(where: {
            $0.turn == turn && $0.kind == .assistant
        })?.id else { return false }
        return visibleItems.contains { item in
            item.turn == turn && item.id != answerID
                && item.kind != .user && item.kind != .context
        }
    }

    /// Folds the closed Turns the current timing mode allows. Completion-time
    /// takes every eligible Turn at once; on-next-message waits until an input
    /// stands after the Turn. Stopped/failed Turns are never auto-folded, and
    /// a Turn the person expanded by hand is never (re-)folded automatically.
    private func autoFoldClosedTurns() {
        let eligible = model.turnEndReasons.filter {
            !["aborted", "interrupted", "error"].contains($0.value)
        }
        guard !eligible.isEmpty else { return }
        for turn in eligible.keys {
            guard !autoFoldedTurns.contains(turn),
                  !manuallyExpandedTurns.contains(turn) else { continue }
            if collapseOnNextMessage {
                guard hasInputAfterTurn(turn) else { continue }
            }
            autoFoldedTurns.insert(turn)
            foldedTurns.insert(turn)
        }
    }

    /// The `On next message` test: does an input row stand after everything
    /// this Turn produced? A steering or trigger row delivered while the Turn
    /// ran belongs to it and does not count as the next message; a prompt the
    /// composer just appended has no Turn number yet and does. When both ends
    /// carry an event time, the end time is the tie-breaker.
    private func hasInputAfterTurn(_ turn: Int) -> Bool {
        guard let lastIndex = visibleItems.lastIndex(where: { $0.turn == turn }) else {
            return false
        }
        let endedAt = model.turnEndTimes[turn]
        return visibleItems[(lastIndex + 1)...].contains { item in
            guard item.kind == .user || item.kind == .context else { return false }
            if let time = item.timestamp, let endedAt { return time > endedAt }
            return item.turn == nil || (item.turn ?? -1) > turn
        }
    }

    /// Identity of the user/steering/trigger inputs. Appending one (a send, a
    /// steer, or a producer trigger) is what lets on-next-message folding run;
    /// streamed assistant deltas must not re-run it.
    private var inputRowSignature: String {
        let inputs = visibleItems.filter { $0.kind == .user || $0.kind == .context }
        return "\(inputs.count)|\(inputs.last?.id ?? "-")"
    }

    /// The card area never takes more than 40% of the screen, scrolls inside
    /// itself when it has more, and folds to one line while the keyboard is up
    /// so the conversation stays visible.
    private var pendingCardCount: Int {
        model.pendingPermission == nil ? 0 : 1
    }

    @ViewBuilder
    private var cardsRegion: some View {
        if pendingCardCount > 0 {
            if keyboardVisible && !cardsExpanded {
                Button {
                    cardsExpanded = true
                } label: {
                    HStack(spacing: 9) {
                        // 「需要处理」是唯一该抢眼的点,全站用同一个警告橙 #B45309。
                        Circle()
                            .fill(ChatPage.warning)
                            .frame(width: 8, height: 8)
                        Text("\(pendingCardCount) 项需要处理")
                            .font(.system(size: 13))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // The question now takes over the composer seat (the
                        // official `conversation.composer` chain); the page-top
                        // region keeps only the approval card.
                        if let permission = model.pendingPermission {
                            permissionCard(permission)
                        }
                    }
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.4)
            }
        }
    }

    @ViewBuilder
    private func queueLine(for item: ChatItem) -> some View {
        // 「发送中…」now has an independent row above the composer (see
        // `pendingSubmissionRow`); keeping it here would print it twice under
        // the same message. The two settled labels stay on the message.
        if let label = model.queueLabel[item.id], label != "发送中…" {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.inkSecondary)
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func failureLineIfNeeded(for item: ChatItem) -> some View {
        if model.failedItemID == item.id, let failure = model.userFacingError {
            failureLine(failure)
        }
    }

    /// 贴在失败那条下面 6 点处的一行:13 号 #C0392B,「没发出去」+ 间距 +「重试」。
    private func failureLine(_ reason: String) -> some View {
        // 一行三段,同一基线:没发出去(红) · 原因(灰,宿主真读到时才有) · 重试(蓝)。
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("没发出去")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChatPage.danger)
            if !reason.isEmpty {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
            }
            if model.failedPrompt != nil {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
                Button("重试") { Task { _ = await model.retryFailedPrompt() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    #if DEBUG
    /// 注入要等记录就绪,否则宿主拉回记录时会把它覆盖掉。
    private func debugInjectIfReady() {
        // A preview page carries its own items, so the state that belongs to
        // one of them (a failure line, a queued label) is applied here instead
        // of waiting for a live turn that never happens.
        if previewItems != nil, let state = debugChatState, !didInjectDebugState {
            didInjectDebugState = true
            switch state {
            case "chat.failed":
                model.debugInstallPreviewState(failedItemID: "p-u2",
                                               error: "示例：这次回合失败了。",
                                               queue: [:])
            case "chat.queued":
                model.debugInstallPreviewState(failedItemID: nil, error: nil,
                                               queue: ["p-u3": "已排队"])
            case "chat.official":
                draft = ""
                model.debugInstallNativeMetricsPreview()
            default:
                break
            }
            return
        }
        guard let state = debugChatState, !didInjectDebugState, model.isTranscriptReady else { return }
        didInjectDebugState = true
        switch state {
        case "chat.failed": model.debugInjectFailure()
        case "chat.queued": model.debugInjectQueued()
        default: break
        }
    }

    private var debugChatState: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiPreview"), args.count > index + 1 else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("chat.") ? value : nil
    }
    #endif

    /// 「没发出去」+ 间距 +「重试」;中间不加标点,也不补半句原因。
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.failedPrompt != nil {
                Button("重试") { Task { _ = await model.retryFailedPrompt() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
            }
            // A host that failed loud stays down until the user acknowledges it
            // (D14). Without this button that acknowledgement was unreachable,
            // so one failure kept the engine from ever booting again.
            if model.engineNeedsReset {
                Button("重新启动引擎") { Task { await model.restartEngine() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
            }
            Button { model.clearError() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .accessibilityLabel("关闭提示")
                .foregroundStyle(ChatPage.inkSecondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func toolFailureBanner(_ item: ChatItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("工具执行失败").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    Text(item.text.components(separatedBy: .newlines).first ?? item.text)
                        .font(.footnote).foregroundStyle(Self.inkSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.06))
    }

    private func commandErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "command").foregroundStyle(.orange)
            Text(message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") { Task { await model.loadCommands() } }
                .font(.footnote.weight(.medium))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Card colours and buttons per the design spec: #F2F3F5 surface, 16pt
    /// inset, 12pt radius, one filled primary action and a plain text deny —
    /// denying is not destructive, so it is not red.
    private func permissionCard(_ permission: ChatPermission) -> some View {
        PermissionCardView(permission: permission,
                           isBusy: model.busy,
                           onAllow: { respond(.allowOnce) },
                           onDeny: { respond(.deny) })
    }


    private func respond(_ decision: PermissionDecision) {
        guard let pending = model.pendingPermission else { return }
        Task { await model.respond(to: pending, decision: decision) }
    }

    /// The design's fixed values, so the card does not drift page by page.
    static let accent = HomeSpec.primaryButton
    static let surface = HomeSpec.surface
    /// #66666B — 5.13:1 on the card surface.
    static let inkSecondary = HomeSpec.textSecondary
    /// 停止类动作的红色,白底 4.89。
    static let danger = Color(red: 0xC0 / 255, green: 0x39 / 255, blue: 0x2B / 255)
    /// 分隔线。
    static let hairline = NativePagePalette.hairline
    /// 警告色 #B45309:只用于状态词和图标,不做整块底色。
    static let warning = Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)

    private var transcript: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.transcriptHasMore {
                            Button {
                                guard !loadingEarlierTranscript else { return }
                                loadingEarlierTranscript = true
                                Task {
                                    await model.loadEarlierTranscript()
                                    loadingEarlierTranscript = false
                                }
                            } label: {
                                HStack {
                                    if loadingEarlierTranscript { ProgressView().controlSize(.small) }
                                    Text(loadingEarlierTranscript ? "正在加载…" : "加载更早消息")
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .disabled(loadingEarlierTranscript)
                        }
                        if let error = model.transcriptError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if model.isShowingCachedTranscript {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("显示上次对话 · 引擎后台启动中…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ChatPage.inkSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                        }
                        if visibleItems.isEmpty { emptyTimeline(viewportHeight: viewport.size.height) }
                        let rows = timelineRows
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            Group {
                            switch row {
                            case .item(let item):
                                VStack(alignment: .leading, spacing: 0) {
                                    ChatMessageRow(item: item, allItems: visibleItems, workspaceFiles: model.files,
                                                   onOpenFile: openWorkspaceResult,
                                                   onOpenPlan: { plan, markdown in
                                                       previewPlan = NativePlanPreview(
                                                           id: plan.id, title: plan.title, markdown: markdown)
                                                   })
                                    queueLine(for: item)
                                    failureLineIfNeeded(for: item)
                                }
                                .id(item.id)
                            case .contexts(let items):
                                NativeContextSourceGroup(items: items)
                                    .id("context-\(items.first?.id ?? "empty")")
                            case .tools(let items):
                                ToolRunRow(items: items, workspaceFiles: model.files,
                                           onOpenFile: openWorkspaceResult)
                                    .id("tool-run-\(items.first?.id ?? "empty")")
                            case .turnProcess(let turn):
                                if let state = model.turnProcessState(for: turn) {
                                    NativeTurnProcessRow(
                                        state: state,
                                        isOpen: !foldedTurns.contains(turn),
                                        isFoldable: turnHasProcess(turn)) {
                                            if foldedTurns.contains(turn) {
                                                foldedTurns.remove(turn)
                                                // Remember the hand-opened Turn:
                                                // no later auto-fold closes it.
                                                manuallyExpandedTurns.insert(turn)
                                            } else {
                                                foldedTurns.insert(turn)
                                                manuallyExpandedTurns.remove(turn)
                                            }
                                        }
                                }
                            case .turnTail(let turn):
                                turnTailRow(turn)
                            }
                            }
                            .padding(.top, Self.spacing(before: index, in: rows))
                        }
                        if model.turnRunning, !visibleItems.isEmpty {
                            NativeRunningStatus(startedAt: model.activeTurnStartedAt,
                                                showsDivider: false)
                                .padding(.top, HomeSpec.blockGap)
                                .id("running-status")
                        }
                        GeometryReader { tail in
                            Color.clear.preference(key: TranscriptTailPreference.self,
                                                   value: tail.frame(in: .named("chat-transcript")).minY)
                        }
                        .frame(height: 1)
                        .id("transcript-tail")
                    }
                    // Home content column: 20pt margins, screen width − 40.
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.top, HomeSpec.blockGap)
                    // Room for the "回到最新" pill (28pt tall) so it never sits
                    // on top of the last rows.
                    .padding(.bottom, 48)
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: TranscriptContentHeightPreference.self,
                                value: content.size.height)
                        })
                }
                .coordinateSpace(name: "chat-transcript")
                .scrollDismissesKeyboard(.interactively)
                .modifier(ScrollInteractionObserver(isInteracting: $userScrolling,
                                                    isSupported: $tracksScrollPhase))
                .defaultScrollAnchor(.bottom)
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(TranscriptContentHeightPreference.self) { height in
                    // The lazy stack reports a growing height while rows
                    // materialize, and every write here invalidates this view:
                    // a sub-pixel difference used to start layout again, which
                    // reported another height. Only a real change publishes.
                    if abs(transcriptContentHeight - height) > 0.5 {
                        transcriptContentHeight = height
                    }
                }
                .onPreferenceChange(TranscriptTailPreference.self) { tailY in
                    scrollTrace.tailOffsetY = tailY
                    // Past the content (a blank viewport) is not "near the
                    // bottom"; neither may a lazy estimate silently re-enable
                    // following while the reader is far above the tail.
                    // The preference fires on every scroll frame; publish only
                    // real transitions so following does not cause layout loops.
                    let near = tailY >= -1 && tailY <= viewport.size.height + 44
                    if nearBottom != near { nearBottom = near }
                    if tracksScrollPhase {
                        // Follow mode belongs to the person: drag away to stop
                        // it, drag back to the tail to resume it.
                        if userScrolling {
                            let away = !near
                            if userScrolledAway != away { userScrolledAway = away }
                        }
                    } else {
                        let away = tailY > viewport.size.height + 44
                        if userScrolledAway != away { userScrolledAway = away }
                    }
                    if near && transcriptContentHeight <= viewport.size.height + 1 {
                        if userScrolledAway { userScrolledAway = false }
                    }
                }
                .onChange(of: transcriptScrollSignature) { _, _ in
                    if pendingInitialScroll, !visibleItems.isEmpty {
                        // Wait for the measured content height: scrolling
                        // before the layout is known cannot prove the content
                        // overflows, and the height change consumes this below.
                        guard transcriptContentHeight > 0 else { return }
                        pendingInitialScroll = false
                        nearBottom = true
                        scrollToTail(proxy, viewportHeight: viewport.size.height)
                        return
                    }
                    guard followsTail, !loadingEarlierTranscript else { return }
                    scheduleTailScroll(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: model.isTranscriptReady) { _, ready in
                    guard ready, pendingInitialScroll, !visibleItems.isEmpty,
                          transcriptContentHeight > 0 else { return }
                    pendingInitialScroll = false
                    nearBottom = true
                    scrollToTail(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: transcriptContentHeight) { _, height in
                    // A freshly opened session measures its history after the
                    // first layout; the pending jump lands here.
                    guard height > 0, !visibleItems.isEmpty else { return }
                    guard pendingInitialScroll else {
                        // Rows that grow without changing the signature (a
                        // list card opening, a tool finishing) keep the tail
                        // in view while following.
                        if followsTail, !loadingEarlierTranscript {
                            scheduleTailScroll(proxy, viewportHeight: viewport.size.height)
                        }
                        return
                    }
                    pendingInitialScroll = false
                    nearBottom = true
                    scrollToTail(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: scrollToLatestTrigger) { _, _ in
                    nearBottom = true
                    userScrolledAway = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollToTail(proxy, viewportHeight: viewport.size.height)
                    }
                }
                .onChange(of: viewport.size.height) { old, new in
                    // The keyboard and the growing composer change the
                    // viewport. A transcript that was following re-anchors to
                    // the tail, so no blank strip is left below the content.
                    guard followsTail else { return }
                    scheduleTailScroll(proxy, viewportHeight: new)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A tap anywhere in the transcript area — rows or the empty space
        // below them — hands the keyboard back. The content shape makes the
        // blank area hit-testable; simultaneous, so rows keep their own taps.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
        .overlay(alignment: .bottom) {
            if userScrolledAway && !nearBottom && !visibleItems.isEmpty {
                Button { scrollToLatestTrigger += 1 } label: {
                    Label("回到最新", systemImage: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Opaque: a translucent capsule let the row underneath
                        // read through and looked like overlapping text.
                        .background(Self.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator)))
                }
                .padding(.bottom, 12)
            }
        }
    }

    /// Whether new content should pull the view to the tail. With scroll
    /// phases (iOS 18+) only an explicit drag away turns it off; before that
    /// the geometric near-bottom test is all there is.
    private var followsTail: Bool {
        tracksScrollPhase ? !userScrolledAway : (nearBottom && !userScrolledAway)
    }

    /// Resigns whichever text input holds the keyboard, even when the focus
    /// flag and the text view's first-responder state have drifted apart.
    private func dismissKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// Scrolls to the transcript's last row, and only when the content
    /// actually overflows: scrolling a shorter transcript to a bottom anchor
    /// overshoots into empty space (the blank page). The last row is a real,
    /// laid-out frame; the lazy tail anchor can be scrolled past its estimate.
    private func scrollToTail(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard transcriptContentHeight > viewportHeight + 1 else { return }
        // The last row may be a folded tool-run group, not the last message;
        // scroll to the row that is actually last.
        if let last = timelineRows.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        } else {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
        }
    }

    /// Follow the tail after the next layout pass.
    ///
    /// Sending a message appends a row and, in the same update, this view asks
    /// the lazy stack to scroll to a row it has not laid out yet: the target
    /// is an estimate, the viewport can end up past the real content (a blank
    /// screen) and the next streamed delta snaps it back (the visible jump).
    /// Debouncing by one short turn lets the height preference and the row
    /// frames settle, and the coalesced follow still tracks streaming.
    /// Whole points for the scroll trace. `Int(_:)` traps on NaN or infinity, which a geometry value
    /// can be before layout settles; the trace must never crash a streaming turn.
    static func traceValue(_ value: CGFloat) -> String {
        value.isFinite && abs(value) < 1e12 ? String(Int(value.rounded())) : String(describing: value)
    }

    private func scheduleTailScroll(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard followsTail else { return }
        tailScrollTask?.cancel()
        tailScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, followsTail else { return }
            if Date().timeIntervalSince(lastScrollTrace) > 1 {
                lastScrollTrace = Date()
                ChatModel.appendDiagnostic(
                    "scroll tail content=\(Self.traceValue(transcriptContentHeight)) viewport=\(Self.traceValue(viewportHeight)) "
                    + "tail=\(Self.traceValue(scrollTrace.tailOffsetY)) near=\(nearBottom) away=\(userScrolledAway)")
            }
            scrollToTail(proxy, viewportHeight: viewportHeight)
        }
    }

    /// 新会话空屏。三种状态互斥,同一时刻只渲染一种;三者都在滚动区里,
    /// 不做覆盖层/浮层。
    /// - A 引擎未启动(优先):`model.isStarted == false`
    /// - B 引擎已启动、模型服务没配好:`providerNeedsKey`
    /// - C 两者都好:居中两行文字
    @ViewBuilder
    private func emptyTimeline(viewportHeight: CGFloat) -> some View {
        if !model.isStarted {
            engineNotStartedState
                .padding(.top, 88)
        } else if providerNeedsKey {
            providerSetupState
                .padding(.top, 88)
        } else {
            readyState(viewportHeight: viewportHeight)
        }
    }

    /// A:引擎还没启动。标题 + 说明 + 黑色主按钮,左右按内容边距 20 撑满。
    private var engineNotStartedState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("引擎还没启动")
                .font(.system(size: 17.5, weight: .semibold))
                .foregroundStyle(HomeSpec.textPrimary)
            Text("启动之后就能开始。")
                .font(.system(size: 14))
                .foregroundStyle(HomeSpec.textPlaceholder)
                .padding(.top, 8)
            Button {
                guard !model.busy else { return }
                Task { await model.start() }
            } label: {
                Text(model.busy ? "正在启动…" : "启动本地引擎")
            }
            .buttonStyle(HomePrimaryButtonStyle())
            .disabled(model.busy)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// B:引擎已启动,只差模型服务。和 A 同一个版式。
    private var providerSetupState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("还差一步:配好模型服务")
                .font(.system(size: 17.5, weight: .semibold))
                .foregroundStyle(HomeSpec.textPrimary)
            Text("选一个模型服务,就能开始。")
                .font(.system(size: 14))
                .foregroundStyle(HomeSpec.textPlaceholder)
                .padding(.top, 8)
            Button {
                showProviderSettings = true
            } label: {
                Text("去配置模型服务")
            }
            .buttonStyle(HomePrimaryButtonStyle())
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// C:引擎与模型都就绪。文字块中心落在「对话区中心 + 24」。
    private func readyState(viewportHeight: CGFloat) -> some View {
        // 滚动内容的 LazyVStack 上、下各留 22 / 48(见 transcript 里的
        // padding)。容器高度取扣除这两段后的可用高度并在其中居中,
        // 再整体下移 24,文字块中心就是视口中心 + 24。
        let topInset: CGFloat = 22
        let bottomInset: CGFloat = 48
        let availableHeight = max(0, viewportHeight - topInset - bottomInset)
        let downwardShift = 24 + (bottomInset - topInset) / 2
        return VStack(spacing: 24) {
            Image("LogoBackground")
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .opacity(colorScheme == .dark ? 0.12 : 0.18)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            VStack(spacing: 4) {
                Text("Phone DSH")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(colorScheme == .dark
                        ? Color(red: 0xC9 / 255, green: 0xC9 / 255, blue: 0xCE / 255)
                        : HomeSpec.textSecondary)
                Text("运行在手机端的 DeepSeek Harness")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(colorScheme == .dark
                        ? Color(red: 0x8A / 255, green: 0x8A / 255, blue: 0x90 / 255)
                        : HomeSpec.textPlaceholder)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: availableHeight)
        .offset(y: downwardShift)
    }

    /// DSH's GoalBar: the session's goal docked above the composer, with a
    /// phase label, the objective and the pause/resume/clear actions (the
    /// same `/goal` command the web client runs).
    private func goalBar(_ goal: HarnessGoal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.inkSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(goalPhaseLabel(goal.phase))
                    .font(.system(size: 11))
                    .foregroundStyle(ChatPage.inkSecondary)
                Text(goal.objective)
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if goal.phase == .active {
                Button("暂停") { runGoalCommand("pause") }
                    .font(.system(size: 12))
            } else if goal.phase == .paused || goal.phase == .blocked {
                Button("继续") { runGoalCommand("resume") }
                    .font(.system(size: 12))
            }
            Button {
                runGoalCommand("clear")
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .accessibilityLabel("清除目标")
        }
        .foregroundStyle(ChatPage.inkSecondary)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(HomeSpec.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func goalPhaseLabel(_ phase: HarnessGoal.Phase) -> String {
        switch phase {
        case .active: return "目标 · 进行中"
        case .paused: return "目标 · 已暂停"
        case .blocked: return "目标 · 已阻塞"
        case .complete: return "目标 · 已完成"
        }
    }

    private func runGoalCommand(_ input: String) {
        Task {
            await runSlashCommand(name: "goal", input: input)
            await model.refreshGoal()
        }
    }

    /// Messages waiting behind the running turn, docked above the input
    /// (DSH's queue strip); the transcript's per-row label still marks the
    /// steered state.
    private var queuedMessages: [ChatItem] {
        visibleItems.filter { model.queueLines[$0.id] == .queued }
    }

    /// Submissions the host accepted but has not begun: they own a pending row
    /// above the composer instead of a label under the user bubble.
    private var sendingMessages: [ChatItem] {
        visibleItems.filter { model.queueLines[$0.id] == .sending }
    }

    /// First line of a message, used by the queue and pending rows.
    private func firstLine(of text: String) -> String {
        text.components(separatedBy: .newlines).first ?? text
    }

    /// Local queue lines in submission order. Each carries the prompt RPC id
    /// that official `QueueDock` uses to retire it when the durable inbox echo
    /// arrives.
    private var localQueueLines: [ComposerQueue.LocalLine] {
        model.queueLineOrder.compactMap { id in
            guard let state = model.queueLines[id] else { return nil }
            guard state == .queued || state == .sending else { return nil }
            guard let item = visibleItems.first(where: { $0.id == id }) else { return nil }
            return ComposerQueue.LocalLine(
                id: id,
                text: item.text,
                state: state == .sending ? .sending : .queued,
                requestID: model.queueLineRequests[id])
        }
    }

    /// The one queue list above the composer: durable `inbox["next-turn"]`
    /// rows first, then local lines whose request id has not been echoed.
    /// Matching is by `source.rpcId`, never by text, so two identical messages
    /// stay two rows and a durable row never loses its inbox id.
    private var composerQueueRows: [ComposerQueue.Row] {
        queue.rows(for: model.currentSessionID,
                   local: localQueueLines,
                   running: model.canSteer)
    }

    /// Everything that can change the durable queue projection: session open,
    /// host/Worker ready or resumed, turn boundaries, a successful send and any
    /// inbox splice. `.task(id:)` coalesces bursts and re-reads the inbox.
    private struct QueueRefreshKey: Equatable {
        let sessionID: String?
        let hostState: String
        let startedAt: Date?
        let transcriptReady: Bool
        let recovering: Bool
        let turnRunning: Bool
        let turnBoundary: Int
        let promptRequestID: String?
        let inboxSpliced: Int
    }

    private var queueRefreshKey: QueueRefreshKey {
        QueueRefreshKey(sessionID: model.currentSessionID,
                        hostState: model.hostState,
                        startedAt: model.startedAt,
                        transcriptReady: model.isTranscriptReady,
                        recovering: model.eventStreamRecovering,
                        turnRunning: model.turnRunning,
                        turnBoundary: model.turnBoundaryRevision,
                        promptRequestID: model.lastPromptRequestID,
                        inboxSpliced: model.inboxSplicedRevision)
    }

    /// Reads the durable next-turn queue. A failure keeps the last rows; the
    /// lifecycle/event triggers retry when the host is ready again.
    @MainActor
    private func refreshComposerQueue(debounced: Bool = false) async {
        guard let sessionID = model.currentSessionID else {
            queue.prepare(for: nil)
            return
        }
        queue.prepare(for: sessionID)
        if debounced {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        guard model.currentSessionID == sessionID, model.isStarted else { return }
        do {
            let transport = try await model.transportForManagement()
            guard !Task.isCancelled, model.currentSessionID == sessionID else { return }
            await queue.refresh(sessionID: sessionID, using: transport)
        } catch {
            // Host starting/stopped: keep the rows already read. The next
            // lifecycle or inbox event retries.
        }
    }

    /// Official `QueueDock` geometry: one row renders without a header; two or
    /// more collapse behind the `{n} 条排队消息` header by default. An open
    /// editor or an in-flight queue action keeps the list expanded.
    @ViewBuilder
    private var queueDock: some View {
        let rows = composerQueueRows
        let editing = queueEditItem != nil
        let expanded = queueExpanded || editing || queueActionBusyID != nil
        let showsLeadingGlyph = rows.count == 1
        VStack(alignment: .leading, spacing: 4) {
            if rows.count > 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { queueExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 14))
                        Text("\(rows.count) 条排队消息")
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                        // The dock expands upward, so the collapsed state
                        // points up (official chevron pair).
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(ChatPage.inkSecondary)
                    .frame(height: 32)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(queueActionBusyID != nil)
                .accessibilityLabel("\(rows.count) 条排队消息")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
            }
            if rows.count == 1 || expanded {
                ForEach(rows) { row in
                    queueRow(row, showsLeadingGlyph: showsLeadingGlyph)
                    if row.id != rows.last?.id {
                        Divider().opacity(0.4).padding(.leading, showsLeadingGlyph ? 38 : 10)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .background(NativeParityTokens.menu,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .alert("编辑排队消息", isPresented: Binding(
            get: { queueEditItem != nil },
            set: { if !$0 { queueEditItem = nil } }
        )) {
            TextField("消息内容", text: $queueEditText)
            Button("取消", role: .cancel) { queueEditItem = nil }
            Button("保存") {
                guard let item = queueEditItem else { return }
                let text = queueEditText.trimmingCharacters(in: .whitespacesAndNewlines)
                queueEditItem = nil
                guard !text.isEmpty else { return }
                Task { await updateQueueItem(item, action: .edit(text)) }
            }
        }
    }

    /// One queue line. The state word and the disabled actions are the official
    /// `queue.sending` row; a durable row offers edit / remove / steer with the
    /// official disabled reasons.
    private func queueRow(_ row: ComposerQueue.Row, showsLeadingGlyph: Bool) -> some View {
        HStack(spacing: 8) {
            if showsLeadingGlyph {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12))
                    .foregroundStyle(NativeChatTheme.tertiary)
                    .frame(width: 16)
            }
            Text(firstLine(of: row.text))
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.state == .sending {
                Text("发送中…")
                    .font(.system(size: 12))
                    .foregroundStyle(NativeChatTheme.tertiary)
                ForEach(["pencil", "trash", "paperplane"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(NativeChatTheme.tertiary.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
            } else {
                queueRowAction(symbol: "pencil", label: "编辑排队消息",
                               reason: queueEditUnavailableReason(row)) {
                    guard let item = row.item, row.editable else { return }
                    queueEditText = item.text
                    queueEditItem = item
                }
                queueRowAction(symbol: "trash", label: "删除排队消息",
                               reason: row.item == nil ? "这条排队消息还没有落盘，暂时不能删除" : nil) {
                    guard let item = row.item else { return }
                    Task { await updateQueueItem(item, action: .remove) }
                }
                queueRowAction(symbol: "paperplane", label: "插话发送",
                               reason: queueSteerUnavailableReason(row)) {
                    guard let item = row.item, row.canSteer else { return }
                    Task { await updateQueueItem(item, action: .steer) }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
    }

    /// One 28pt icon action with a 44pt target and the official disabled reason.
    private func queueRowAction(symbol: String, label: String, reason: String?,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(reason == nil ? NativeChatTheme.secondary : NativeChatTheme.tertiary.opacity(0.5))
                .frame(width: 28, height: 28)
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil || queueActionBusyID != nil)
        .accessibilityLabel(label)
        .help(reason ?? label)
    }

    /// The edit action is available only for a durable, purely textual entry
    /// with non-empty content; DSH rejects everything else.
    private func queueEditUnavailableReason(_ row: ComposerQueue.Row) -> String? {
        guard let item = row.item else { return "这条排队消息还没有落盘，暂时不能编辑" }
        guard item.isPlainText else { return "包含非文本内容，暂不支持编辑" }
        guard row.editable else { return "消息内容为空，暂不支持编辑" }
        return nil
    }

    /// Official `QueueDock` gates steering on the running agent; this app also
    /// waits for transcript/stream readiness (`model.canSteer`).
    private func queueSteerUnavailableReason(_ row: ComposerQueue.Row) -> String? {
        guard let item = row.item else { return "这条排队消息还没有落盘，暂时不能插话发送" }
        guard item.lane == "next-turn" else { return "仅下一轮排队消息可以插话发送" }
        guard model.turnRunning else { return "仅运行中可插话发送" }
        guard model.canSteer else { return "当前暂时不能插话发送" }
        return nil
    }

    /// Runs one queue action on the dedicated store. The store re-reads the
    /// durable inbox on success and failure; edit/remove failures become a
    /// composer notice, while steer's two convergence codes stay silent.
    @MainActor
    private func updateQueueItem(_ item: ComposerQueue.Item, action: ComposerQueue.Action) async {
        queueActionBusyID = item.id
        defer { queueActionBusyID = nil }
        do {
            let transport = try await model.transportForManagement()
            let result = await queue.perform(action, on: item, sessionID: item.sessionID,
                                             using: transport)
            if let message = result.visibleError {
                composerNotice = ComposerNotice(level: .error, text: message)
            }
        } catch {
            composerNotice = ComposerNotice(level: .error,
                                            text: "排队消息操作失败：\(error.localizedDescription)")
        }
    }

    /// Independent pending row above the composer: spinner + 「发送中…」+ the
    /// message's first line, in the queue strip's geometry. It is one row per
    /// dispatching submission, and it never doubles as a label under the
    /// bubble (see `queueLine`).
    private var pendingSubmissionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sendingMessages) { item in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("发送中…")
                        .font(.system(size: 13))
                        .foregroundStyle(ChatPage.inkSecondary)
                    Text(firstLine(of: item.text))
                        .font(.system(size: 13))
                        .foregroundStyle(NativeChatTheme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(NativeParityTokens.menu,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("发送中：\(firstLine(of: item.text))")
            }
        }
    }

    /// Official `conversation.composer` takeover: while a question is pending,
    /// the card replaces the composer instead of floating above the transcript.
    @ViewBuilder
    private func questionTakeover(_ question: HarnessQuestion) -> some View {
        if let (review, item) = planReview(from: question) {
            NativePlanReviewCard(
                review: review,
                onApprove: { submitPlanApproval(item) },
                onRequestChanges: { model.dismissQuestion() })
                .padding(.horizontal, NativeParityTokens.composerSide)
                .padding(.bottom, 8)
                .background(HomeSpec.page)
        } else {
            NativeQuestionComposer(
                questions: nativeQuestionItems(question),
                requestKey: question.requestID,
                isSubmitting: false,
                channelAvailable: true,
                viewportHeight: UIScreen.main.bounds.height,
                onSubmit: { submitQuestion($0) },
                onDiscard: { model.dismissQuestion() },
                onClose: { model.dismissQuestion() })
                .padding(.horizontal, NativeParityTokens.composerSide)
                .padding(.bottom, 8)
                .background(HomeSpec.page)
        }
    }

    /// Official `planReviewOf`: exactly one question carrying a plan detail and
    /// an `intent.kind == "plan-review"` with the named approve option.
    private func planReview(from question: HarnessQuestion) -> (NativePlanReviewData, HarnessQuestionItem)? {
        guard let items = question.questions, items.count == 1,
              let item = items.first,
              item.intentKind == "plan-review",
              let detail = item.detail, !detail.isEmpty,
              item.approve != nil else { return nil }
        return (NativePlanReviewData(question: item.prompt, markdown: detail), item)
    }

    private func submitPlanApproval(_ item: HarnessQuestionItem) {
        guard let approve = item.approve else { return }
        let values = [item.id: [approve]]
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else { return }
        Task { await model.respondToQuestion(answer: encoded) }
    }

    private func nativeQuestionItems(_ question: HarnessQuestion) -> [NativeQuestionItem] {
        let items = question.questions
            ?? [HarnessQuestionItem(id: "answer", prompt: question.prompt, options: question.options)]
        return items.map { item in
            NativeQuestionItem(
                id: item.id,
                header: item.header,
                question: item.prompt,
                detail: item.detail,
                options: item.options.map { NativeQuestionOption(label: $0, description: nil) },
                multiSelect: item.multiple)
        }
    }

    private func submitQuestion(_ batch: NativeQuestionAnswerBatch) {
        var values: [String: Any] = [:]
        for answer in batch.answers {
            if answer.skipped {
                values[answer.id] = [String]()
                continue
            }
            var selected = answer.selected
            if let custom = answer.custom?.trimmingCharacters(in: .whitespacesAndNewlines),
               !custom.isEmpty {
                selected.append(custom)
            }
            values[answer.id] = selected
        }
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else { return }
        Task { await model.respondToQuestion(answer: encoded) }
    }

    /// Everything docked above the card (todos, goal, queue, notices, menus).
    /// Type-erased with the card: inlined together they make `composer`'s
    /// generic type deep enough to overflow the main-thread stack when a
    /// Debug build instantiates it at launch.
    private var composerDocks: AnyView {
        AnyView(VStack(spacing: NativeParityTokens.flowGap) {
            if !model.todoDockItems.isEmpty {
                NativeTodoDock(todos: model.todoDockItems, width: NativeParityTokens.contentWidth)
            }
            if let goal = model.goal { goalBar(goal) }
            if voice.recognizing || !voice.status.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13))
                    Text(voice.status)
                        .font(.system(size: 13))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("取消") { voice.cancel() }
                        .font(.system(size: 13, weight: .medium))
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(HomeSpec.textSecondary)
                .padding(.horizontal, 4)
            }
            if !composerQueueRows.isEmpty { queueDock }
            // B1: the dispatching submission is its own row, not a label
            // under the user bubble.
            if !sendingMessages.isEmpty { pendingSubmissionRow }
            if !pendingAttachments.isEmpty { attachmentStrip }
            if let attachmentError {
                HStack {
                    Text(attachmentError).font(.footnote).foregroundStyle(.red)
                    Spacer()
                    Button("关闭") { self.attachmentError = nil }.font(.footnote)
                }
            }
            if model.turnRunning && busyEnterMode == "steer" && !pendingAttachments.isEmpty {
                Text("补充说明不支持附带图片；请切换为“排入下一轮”或移除图片。")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let fileImportNotice {
                HStack {
                    Text(fileImportNotice).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("关闭") { self.fileImportNotice = nil }.font(.footnote)
                }
            }
            // Official `InputBar` notice channel: command settlement and the
            // attachment refusal land above the card instead of a page banner.
            if let composerNotice { composerNoticeRow(composerNotice) }
            if isExecutingCommand, let executingCommandName, executingCommandName == "compact" {
                composingStatusRow(NativeCompaction.running)
            }
            // The DSH input trigger: a bare leading `/token` opens the command
            // menu in place; picking one writes the token back into the draft
            // (or executes a command that declares no input).
            if slashMenuVisible { slashCommandMenu }
            if referenceToken != nil { referenceMenu }
        })
    }

    private var composer: some View {
        VStack(spacing: NativeParityTokens.flowGap) {
            composerDocks
            AnyView(composerCard)
            NativeComposerStats(stats: model.sessionStats, usage: model.tokenUsage,
                                pressure: model.contextPressure, breakdown: model.contextBreakdown)
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, 8)
        // The composer (or its stats line) sits right on the bottom menu's top
        // edge; the menu's own 14pt top inset gives the icons their air.
        .padding(.bottom, 0)
        .background(HomeSpec.page)
        // The command catalog is pulled the first time the trigger opens, the
        // same lazy load the DSH command directory does per session.
        .onChange(of: slashToken) { _, token in
            slashMenuDismissed = false
            slashHighlight = 0
            guard token != nil, model.availableCommands.isEmpty,
                  !model.commandsLoading else { return }
            Task { await model.loadCommands() }
        }
        // A command-result sheet takes the keyboard; hand it back to the
        // composer when the sheet closes (the bar owned focus before the sheet
        // opened, exactly like the web composer never losing it).
        .onChange(of: showCommandResult) { _, showing in
            guard !showing, restoreComposerFocus else { return }
            restoreComposerFocus = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                inputFocused = true
            }
        }
    }

    /// Home composer (HomeSpec): one 104pt+ white card, r24. The text area
    /// sits on top; the full control row (+, 语音, 权限, 模型, 发送) is always
    /// docked inside the lower edge, so no tool hides behind a focus state.
    private var composerCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(composerPlaceholder)
                            .font(.system(size: HomeSpec.bodySize))
                            .foregroundStyle(HomeSpec.inputPlaceholder)
                            .lineLimit(2)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    NativeComposerTextView(
                        text: $draft,
                        isFocused: $inputFocused,
                        isEditable: composerEnabled,
                        fontSize: HomeSpec.bodySize,
                        lineSpacing: HomeSpec.lineSpacing(size: HomeSpec.bodySize,
                                                          lineHeight: HomeSpec.bodyLine),
                        maxHeight: 336,
                        menuOpen: slashMenuVisible,
                        accessibilityLabel: composerPlaceholder,
                        onReturn: { handleComposerReturn(accelerated: $0) },
                        onMenuKey: { handleComposerMenuKey($0) },
                        onHeightChange: { composerHeight = $0 })
                        .frame(height: max(56, composerHeight))
                }
                .frame(minHeight: 36)
            }
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .onChange(of: draft) { _, value in
                if value.count > 8_000 {
                    draft = String(value.prefix(8_000))
                    if !pasteLimitNoticed {
                        pasteLimitNoticed = true
                        attachmentError = "已截断到 8000 字。"
                    }
                }
            }

            composerControls
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .frame(height: 44)
                .padding(.top, 4)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: HomeSpec.composerOpenMinHeight)
        .background(HomeSpec.surface,
                    in: RoundedRectangle(cornerRadius: HomeSpec.composerOpenRadius, style: .continuous))
        .homeComposerShadow()
        .contentShape(Rectangle())
        .onTapGesture { if composerEnabled { inputFocused = true } }
    }

    /// Official `InputBar` notice: one 12pt status line above the card, info or
    /// error, dismissible.
    private func composerNoticeRow(_ notice: ComposerNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.level == .error ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 12))
            Text(notice.text)
                .font(.system(size: 12))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                composerNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .foregroundStyle(notice.level == .error ? Color.red : NativeChatTheme.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    /// A running long command's own status line (`/compact` → 正在压缩…).
    private func composingStatusRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 12)).foregroundStyle(NativeChatTheme.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        if !canSubmit && model.turnRunning {
            stopButton
        } else {
            Button { submitDraft() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSubmit ? HomeSpec.primaryButtonInk : HomeSpec.iconMuted)
                    .frame(width: HomeSpec.sendButton, height: HomeSpec.sendButton)
                    .background(canSubmit ? HomeSpec.primaryButton : HomeSpec.userBubble, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .animation(.easeOut(duration: 0.12), value: canSubmit)
            .accessibilityLabel(sendButtonLabel)
        }
    }

    /// 36pt black circle with a white rounded square (HomeSpec).
    private var stopButton: some View {
        Button {
            guard !stopping else { return }
            stopping = true
            Task {
                await model.cancelTurn()
                stopping = false
            }
        } label: {
            Group {
                if stopping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HomeSpec.primaryButtonInk)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(HomeSpec.primaryButtonInk)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: HomeSpec.sendButton, height: HomeSpec.sendButton)
            .background(HomeSpec.primaryButton.opacity(stopping ? 0.6 : 1), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stopping ? "正在停止" : "停止执行")
    }

    /// The 语音 button is hidden for now; dictation stays wired up so turning
    /// this back on restores it.
    static let showsVoiceInput = false

    /// Control row inside the card: + , 语音 (when shown), 权限 and the plan chip on the
    /// left in 40×44 hit boxes, the model chip and the 36pt send/stop button
    /// on the right, 8pt from the card edge.
    private var composerControls: some View {
        HStack(spacing: 0) {
            composerPlusMenu(tint: HomeSpec.primaryButton)
            if Self.showsVoiceInput {
                Button {
                    if voice.recording { voice.finish() }
                    else { voice.start { text in draft += (draft.isEmpty ? "" : "\n") + text } }
                } label: {
                    Image(systemName: voice.recording ? "stop.circle.fill" : "mic")
                        .font(.system(size: 19, weight: .regular))
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(voice.recording ? ChatPage.danger : HomeSpec.textSecondary)
                .accessibilityLabel(voice.recording ? "结束语音输入" : "语音输入")
                .disabled(voice.recognizing && !voice.recording)
            }
            accessModeMenu
                .frame(minWidth: 40)
            if let plan = model.planModeState, plan.isPlanTarget {
                NativePlanChip(mode: plan,
                               isLocked: model.pendingQuestion != nil || model.pendingPermission != nil,
                               onExit: { Task { await model.exitPlanMode() } })
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            modelMenu
                .layoutPriority(-1)
            HStack(spacing: 8) {
                if model.turnRunning, canSubmit { stopButton }
                actionButton
            }
            .padding(.leading, 8)
        }
    }

    private func composerPlusMenu(tint: Color) -> some View {
        Menu {
            Button("调用指令", systemImage: "slash.square") {
                draft = "/"
                inputFocused = true
            }
            Button("引用文件或对话", systemImage: "at") {
                draft = "@"
                inputFocused = true
            }
            Button("添加图片", systemImage: "photo") { showAttachmentPicker = true }
            Button(voice.speaking ? "停止朗读" : "朗读最近回复", systemImage: "speaker.wave.2") {
                if voice.speaking { voice.stopSpeaking() }
                else if let text = model.items.last(where: { $0.kind == .assistant })?.text { voice.speak(text) }
            }
            .disabled(!voice.speaking && !model.items.contains(where: { $0.kind == .assistant && !$0.text.isEmpty }))
            Button("添加文件（写入工作区）", systemImage: "doc.badge.plus") {
                showFileImport = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(tint)
                .frame(width: HomeSpec.composerIcon, height: HomeSpec.composerIcon)
                .frame(minWidth: 40, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!composerEnabled)
        .accessibilityLabel("添加指令、引用或附件")
    }

    /// 菜单照宿主的目录来:有几项列几项、顺序也照宿主的,我们只翻名字。
    /// 不合并、不删减;翻不出中文的档不列,只在当前生效时报一句状态。
    private var listedAccessModes: [NativeAccessMode] {
        var seen = Set<String>()
        var modes = model.availableAccessModes.filter { mode in
            guard let title = AccessModeWording.title(for: mode.id) else { return false }
            return seen.insert(title).inserted   // 两个 id 叫同一个名字时只出现一行
        }
        // 「完全权限」钉在最后一行可选行:最松的一档离手指最远。
        if let index = modes.firstIndex(where: { AccessModeWording.title(for: $0.id) == "完全权限" }) {
            modes.append(modes.remove(at: index))
        }
        // 这块菜单从输入框往上弹:系统把数组第一项画在最下面,
        // 所以数组要倒过来写,屏幕上才是从上到下 仅可查看 → 工作区内修改 → 完全权限。
        return modes.reversed()
    }

    /// 当前组合没匹配上任何预设时,在可选行之后报一句状态:给人看,不能点。
    private var currentStatusText: String? {
        AccessModeWording.statusText(forCurrent: model.currentAccessMode)
    }

    private var accessModeMenu: some View {
        Menu {
            // 系统菜单项只能一行字,加不了小字说明;用分组标题顶上那一行,
            // 把「为什么还会弹卡」说在前面:只写问不问那一半,不带档位名。
            if let error = model.accessModeError {
                Section("暂不可用") { Text(error) }
            }
            if model.availableAccessModes.isEmpty {
                Text("没有可切换的权限。")
            } else {
                let modes = listedAccessModes
                if modes.isEmpty {
                    Text("没有可切换的权限。")
                } else {
                    if let status = currentStatusText {
                        Text(status)
                            .foregroundStyle(Self.inkSecondary)
                            .disabled(true)
                    }
                    Section {
                    ForEach(modes) { mode in
                        Button {
                            if mode.id == "bypassPermissions" || mode.id == "danger-full-access" || mode.id == "phone" {
                                confirmAccessMode = mode
                            } else {
                                Task { await selectAccessMode(mode) }
                            }
                        } label: {
                            let title = AccessModeWording.title(for: mode.id) ?? ""
                            if mode.id == model.currentAccessMode {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                        .disabled(isSelectingAccessMode)
                    }
                    } header: {
                        // 系统菜单项只能一行,小字说明放不进项里;用分组标题说清「为什么还会弹卡」,
                        // 标题只写问不问那一半,档位名交给下面带勾的那行。
                        Text(AccessModeWording.title(for: model.currentAccessMode ?? "") == "完全权限"
                             ? "写之前不再问你" : "每次写之前会先问你")
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                NativeChatIcon(name: .shield, size: 20)
                    .overlay(alignment: .topTrailing) {
                        // Reads failed even after the automatic retries: a quiet
                        // mark on the control instead of a page banner.
                        if model.accessModeError != nil && !model.accessModeLoading {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -1)
                        }
                    }
                if model.accessModeLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                } else {
                    NativeChatIcon(name: .chevronDown, size: 10)
                }
            }
            .foregroundStyle(HomeSpec.iconMuted)
            .frame(height: HomeSpec.sendButton)
            .contentShape(Rectangle())
        }
        // Opening the menu after a failed read starts the automatic read again.
        .simultaneousGesture(TapGesture().onEnded {
            if model.accessModeError != nil && !model.accessModeLoading {
                Task { await model.refreshAccessModes() }
            }
        })
        .disabled(!model.canSend || model.turnRunning || model.pendingQuestion != nil || model.pendingPermission != nil || isSelectingAccessMode)
        .accessibilityLabel(model.accessModeLoading ? "权限：正在读取" : "权限：\(accessModeTitle)")
    }
    private var accessModeTitle: String {
        if let current = model.currentAccessMode,
           let title = AccessModeWording.title(for: current) {
            return title
        }
        return "权限"
    }

    private var accessModeConfirmationTitle: String {
        guard let mode = confirmAccessMode,
              let title = AccessModeWording.title(for: mode.id) else { return "切换权限？" }
        return "开启「\(title)」？"
    }

    @MainActor
    private func selectAccessMode(_ mode: NativeAccessMode) async {
        isSelectingAccessMode = true
        defer { isSelectingAccessMode = false }
        _ = await model.selectAccessMode(mode.id)
    }

    private var modelMenu: some View {
        Menu {
            if management.modelRoutes.isEmpty {
                Label("模型目录暂不可用", systemImage: "exclamationmark.circle")
            } else {
                // 这块菜单从输入框往上弹,系统把数组里的先后整个倒过来画:
                // 所以「强度」段写在前面、段内条目也倒着给,屏幕上才是
                // 上面「模型」、下面「强度」,每段里顺序正常。
                if let route = currentRoute, !route.reasoningEfforts.isEmpty {
                    Section("强度") {
                        ForEach(route.reasoningEfforts.reversed()) { effort in
                            Button {
                                Task { await management.selectModel(route, reasoningEffort: effort.id) }
                            } label: {
                                if management.currentModelSelection?.reasoningEffort == effort.id {
                                    Label(effortTitle(effort), systemImage: "checkmark")
                                } else {
                                    Text(effortTitle(effort))
                                }
                            }
                        }
                        Button {
                            Task { await management.selectModel(route, reasoningEffort: nil) }
                        } label: {
                            // 「默认强度」不是一档,是「按这个模型自己那档来」:
                            // 后面跟上它现在实际等于哪个档,点了才不会没底。
                            let defaultTitle = defaultEffortTitle(for: route)
                            if management.currentModelSelection?.reasoningEffort == nil {
                                Label(defaultTitle, systemImage: "checkmark")
                            } else {
                                Text(defaultTitle)
                            }
                        }
                    }
                }
                Section("模型") {
                    ForEach(listedModelRoutes.reversed()) { route in
                        Button {
                            Task { await management.selectModel(route, reasoningEffort: keptEffort(for: route)) }
                        } label: {
                            if management.currentModelSelection?.model == route.model {
                                Label(route.model, systemImage: "checkmark")
                            } else {
                                Text(route.model)
                            }
                        }
                    }
                }
            }
        } label: {
            // 这一行只放模型名,强度收进菜单里选:名字要一眼认得出,
            // 宁可少一个「Max」,也不能把模型名截成 deepseek-…。
            modelNameBlock
        }
        .disabled(!model.canSend || model.turnRunning || model.pendingQuestion != nil || model.pendingPermission != nil)
        .accessibilityLabel("选择模型")
    }

    private var modelControlTint: Color {
        model.canSend ? HomeSpec.textPrimary : HomeSpec.textPlaceholder
    }

    /// The mode chip (HomeSpec "⚡ 快速 ⌄"): bolt, 16pt model name, chevron.
    private var modelNameBlock: some View {
        HStack(spacing: 6) {
            Text(modelDisplayName)
                .font(.system(size: HomeSpec.bodySize))
                .lineLimit(1)
                .truncationMode(.tail)
            if let effort = reasoningEffortTitle {
                Text(effort)
                    .font(.system(size: HomeSpec.bodySize))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
        }
        .foregroundStyle(modelControlTint)
        .frame(height: HomeSpec.sendButton)
        .contentShape(Rectangle())
        .layoutPriority(1)
    }

    private func reasoningEffortBlock(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .lineLimit(1)
            .foregroundStyle(modelControlTint)
            .padding(.horizontal, 4)
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    /// 换模型时,如果新模型也支持现在这档强度,就保持不动;不支持就回到默认。
    private func keptEffort(for route: ManagedModelRoute) -> String? {
        guard let effort = management.currentModelSelection?.reasoningEffort,
              route.reasoningEfforts.contains(where: { $0.id == effort }) else { return nil }
        return effort
    }

    private var currentRoute: ManagedModelRoute? {
        guard let selection = management.currentModelSelection else { return nil }
        return management.modelRoutes.first {
            $0.provider == selection.provider && $0.model == selection.model
        }
    }

    /// 强度只上中文:宿主的英文名(Off / Low / High / Max)不上屏。
    private func effortTitle(_ effort: ManagedReasoningEffort) -> String {
        switch effort.id.lowercased() {
        case "off", "none", "disabled": return "关"
        case "low", "minimal": return "低"
        case "medium", "mid": return "中"
        case "high": return "高"
        case "max", "maximum", "xhigh": return "最高"
        default: return effort.name
        }
    }

    /// 「默认强度」后面补上它现在等价的档,例如「默认强度 · 高」。
    private func defaultEffortTitle(for route: ManagedModelRoute) -> String {
        guard let id = route.defaultEffort,
              let effort = route.reasoningEfforts.first(where: { $0.id == id }) else { return "默认强度" }
        return "默认强度 · \(effortTitle(effort))"
    }

    /// 模型菜单里一行一个模型,只写模型名:同一个模型被两个提供商报了也只出现一次。
    private var listedModelRoutes: [ManagedModelRoute] {
        var seen = Set<String>()
        return management.modelRoutes.filter { seen.insert($0.model).inserted }
    }

    private var modelDisplayName: String {
        if let selection = management.currentModelSelection { return selection.model }
        return model.modelName.isEmpty ? "模型" : model.modelName
    }

    private var reasoningEffortTitle: String? {
        guard let selection = management.currentModelSelection,
              let effortID = selection.reasoningEffort,
              let route = management.modelRoutes.first(where: {
                  $0.provider == selection.provider && $0.model == selection.model
              }),
              let effort = route.reasoningEfforts.first(where: { $0.id == effortID }) else {
            return nil
        }
        return effort.name
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                    HStack(spacing: 5) {
                        Image(systemName: "photo")
                        Text(attachment.name).lineLimit(1)
                        Button { pendingAttachments.remove(at: index) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("移除图片 \(attachment.name)")
                    }
                    .font(.caption)
                    .padding(.leading, 10)
                    .padding(.trailing, 2)
                    .background(HomeSpec.userBubble, in: Capsule())
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var composerEnabled: Bool {
        guard model.pendingQuestion == nil, model.pendingPermission == nil, !isSelectingAccessMode else { return false }
        if model.turnRunning { return busyEnterMode == "steer" ? model.canSteer : model.canSend }
        return model.canSend || model.canStartBySending
    }

    private var canSubmit: Bool {
        guard composerEnabled else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model.turnRunning && busyEnterMode == "steer" {
            return hasText && pendingAttachments.isEmpty
        }
        return model.turnRunning ? hasText : (hasText || !pendingAttachments.isEmpty)
    }

    /// Official `resolveSubmitMode`: plain Enter (and the Send button) uses the
    /// busy-Enter preference; the ⌘/Ctrl+Enter accelerator takes the opposite
    /// delivery. Outside a running turn, or when this transport cannot steer,
    /// every gesture queues.
    private func usesSteerDelivery(accelerated: Bool) -> Bool {
        guard model.turnRunning, model.canSteer else { return false }
        let preferred = busyEnterMode == "steer"
        return accelerated ? !preferred : preferred
    }

    private func submitDraft(accelerated: Bool = false) {
        let text = draft
        if let command = Self.parseSlashCommand(text) {
            draft = ""
            slashMenuDismissed = false
            Task { await runSlashCommand(name: command.name, input: command.input) }
            return
        }
        let steer = usesSteerDelivery(accelerated: accelerated)
        if steer, !pendingAttachments.isEmpty {
            composerNotice = ComposerNotice(level: .error,
                                            text: "补充说明不支持附带图片；请先移除图片，或改用排队发送。")
            return
        }
        let wasRunning = model.turnRunning
        // 一按发送就清空:失败那条留在气泡里,重试原样再发,新打的字进新气泡。
        draft = ""
        slashMenuDismissed = false
        Task {
            let succeeded: Bool
            if steer {
                succeeded = await model.steer(text)
            } else {
                succeeded = await model.send(text, attachments: pendingAttachments)
                if succeeded {
                    nearBottom = true
                    userScrolledAway = false
                    scrollToLatestTrigger += 1
                }
            }
            if succeeded {
                // 发送即收起键盘。官方 Web 端发完保持聚焦（输入框就是 combobox），
                // 但手机上键盘会盖住刚发出去的那条和回复，也没有"再打一句"的富余
                // 空间；要接着打字的人点一下输入框就能重新唤起。
                // c922fe7 为对齐官方把这条收掉了，实际用起来是退化。
                inputFocused = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                ChatModel.appendDiagnostic("composer: released focus after send")
                let id = model.items.last(where: { if case .user = $0.kind { return true }; return false })?.id
                if let id {
                    // `send` sets turnRunning for the turn it just started, so
                    // an ordinary idle send used to be labelled "已排队" for a
                    // moment. The label describes the queue the message joined,
                    // which only exists if a turn was already running.
                    if wasRunning && steer {
                        model.markSteered(itemID: id)
                    } else if wasRunning {
                        model.markQueued(itemID: id, requestID: model.lastPromptRequestID)
                        ChatModel.appendDiagnostic("queued: \(text.prefix(40))")
                    }
                }
                pendingAttachments.removeAll()
                attachmentError = nil
                // The keyboard is released above, so the transcript regains the
                // height it lost while composing. Either way a send means "show
                // me the newest turn": the composer and the keyboard change the
                // transcript viewport, which used to leave `nearBottom` false
                // even though the person never scrolled away; the new row then
                // stayed below the fold. Jump to the tail through the
                // session-open path (no animation).
                nearBottom = true
                userScrolledAway = false
                pendingInitialScroll = true
            } else if draft.isEmpty {
                // The send was refused before it produced a row (host not
                // ready, session switching, busy): keep the text so the person
                // can retry instead of losing the message.
                draft = text
            }
        }
    }

    /// Plain Return / the keyboard's 发送 key. Returns true when consumed: a
    /// menu pick, a submitted draft, or a refused submit (official keymap
    /// never inserts a newline on a bare Enter).
    private func handleComposerReturn(accelerated: Bool) -> Bool {
        let matches = slashMatches
        if slashMenuVisible, !matches.isEmpty {
            pickCommand(matches[min(slashHighlight, matches.count - 1)])
            return true
        }
        guard canSubmit else { return true }
        submitDraft(accelerated: accelerated)
        return true
    }

    /// Hardware-key arbitration for the open slash menu (`↑`/`↓`/`Tab`/`Esc`).
    private func handleComposerMenuKey(_ key: ComposerMenuKey) -> Bool {
        let matches = slashMatches
        switch key {
        case .up:
            guard slashMenuVisible, !matches.isEmpty else { return false }
            slashHighlight = max(0, slashHighlight - 1)
            return true
        case .down:
            guard slashMenuVisible, !matches.isEmpty else { return false }
            slashHighlight = min(matches.count - 1, slashHighlight + 1)
            return true
        case .tab:
            guard slashMenuVisible, !matches.isEmpty else { return false }
            pickCommand(matches[min(slashHighlight, matches.count - 1)])
            return true
        case .escape:
            if slashMenuVisible {
                // Official Escape layering closes the menu and keeps the
                // draft; the next keystroke re-opens it.
                slashMenuDismissed = true
                return true
            }
            if model.turnRunning {
                stopRun()
                return true
            }
            inputFocused = false
            return true
        }
    }

    private func stopRun() {
        guard !stopping else { return }
        stopping = true
        Task {
            await model.cancelTurn()
            stopping = false
        }
    }

    @MainActor
    private func executeCommand(_ descriptor: NativeCommandDescriptor, input: String,
                                attachments: [HarnessAttachment]) async {
        guard !isExecutingCommand else { return }
        guard attachments.isEmpty || descriptor.acceptsAttachments else {
            composerNotice = ComposerNotice(level: .error,
                                            text: NativeCommandCatalog.attachmentRefusal(for: descriptor.name))
            return
        }
        isExecutingCommand = true
        executingCommandName = descriptor.name
        // A sheet takes the keyboard; remember to hand it back afterwards.
        restoreComposerFocus = inputFocused
        defer {
            isExecutingCommand = false
            executingCommandName = nil
        }
        guard let result = await model.executeCommand(name: descriptor.name, input: input,
                                                      attachments: attachments) else {
            let message = model.commandsError ?? "没执行成功，再试一次。"
            model.dismissCommandsError()
            composerNotice = ComposerNotice(level: .error, text: message)
            restoreComposerFocus = false
            return
        }
        if result.kind == "success" {
            pendingAttachments.removeAll()
            attachmentError = nil
        }
        let settlement = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Official surfaces the command settlement as a composer notice; the
        // durable command/done record is the transcript's copy. A manual
        // compaction is folded into its 上下文已压缩 marker, so the phone does
        // not open the result sheet for it (the marker already carries the
        // count the text repeats).
        if result.name == "compact" || result.kind != "success" {
            model.dismissCommandsError()
            composerNotice = ComposerNotice(
                level: result.kind == "success" ? .info : .error,
                text: settlement.isEmpty
                    ? (result.kind == "success" ? "已完成 /\(result.name)" : "命令执行失败")
                    : settlement)
            restoreComposerFocus = false
            if result.kind == "success" { showCommandResult = false }
            return
        }
        commandExecution = result
        showCommandResult = true
    }

    private func openWorkspaceResult(_ path: String) {
        let normalized = Self.normalizedWorkspacePath(path)
        guard !normalized.isEmpty, !normalized.split(separator: "/").contains("..") else {
            attachmentError = "这个路径不能预览。"
            return
        }
        // A tool can write a file seconds before its bytes are materialized
        // here; the cached list is therefore a hint, not the authority. Refresh
        // and retry, then fall back to a unique basename match before saying
        // anything failed.
        if !model.files.contains(where: { $0.relativePath == normalized }) {
            model.refreshFiles()
        }
        // The tool result and the file list can disagree only in Unicode
        // normalization (a Chinese name written NFC, listed NFD); try the
        // canonical spelling before falling back to a unique basename.
        let canonical = normalized.precomposedStringWithCanonicalMapping
        if let match = model.files.first(where: { $0.relativePath == normalized })
            ?? model.files.first(where: { $0.relativePath.precomposedStringWithCanonicalMapping == canonical })
            ?? (normalized.contains("/") ? nil : Self.uniqueBasenameMatch(normalized, in: model.files)) {
            // One tap: open the preview directly. The preview model owns the
            // write-in-flight wait, so no Workbench hop is needed here.
            previewTarget = .workspaceFile(match.relativePath)
            return
        }
        // The write may still be in flight. Let the preview surface show the
        // waiting state and retry in place; never bounce through Workbench.
        previewTarget = .workspaceFile(normalized)
        pendingPreviewPath = normalized
    }

    /// Accepts the shapes a tool result or markdown link can produce:
    /// `/dsh/workspace/a.pdf`, `file:///…/a.pdf`, `sandbox:a.pdf`, `./a.pdf`.
    static func normalizedWorkspacePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["file://", "sandbox:"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        if let decoded = path.removingPercentEncoding { path = decoded }
        if path.hasPrefix("/dsh/workspace/") {
            path = String(path.dropFirst("/dsh/workspace/".count))
        }
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        // A Chinese name can arrive decomposed (NFD) from a tool result while
        // the materialized tree lists it composed (NFC); compare in one form.
        path = path.precomposedStringWithCanonicalMapping
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func uniqueBasenameMatch(_ path: String, in files: [WorkspaceFile]) -> WorkspaceFile? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let wanted = name.precomposedStringWithCanonicalMapping
        let matches = files.filter { file in
            let candidate = file.relativePath.split(separator: "/").last.map(String.init) ?? file.relativePath
            return candidate.precomposedStringWithCanonicalMapping == wanted
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private var composerPlaceholder: String {
        if !model.turnRunning { return "发消息或创建任务，/ 调用指令，@ 文件或对话" }
        return busyEnterMode == "steer" ? "补充当前任务…" : "排入下一轮…"
    }

    private var sendButtonLabel: String {
        guard model.turnRunning else { return "发送消息" }
        return busyEnterMode == "steer" ? "补充当前任务" : "排入下一轮"
    }

    private static var imageContentTypes: [UTType] {
        [.png, .jpeg, .gif] + [UTType(filenameExtension: "webp")].compactMap { $0 }
    }

    private func loadAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentError = "无法读取所选图片：\(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let existingCount = pendingAttachments.count
            let existingBytes = pendingAttachments.reduce(0) { $0 + $1.data.count }
            let limits = model.imageLimits
            Task {
                do {
                    let attachments = try await Task.detached(priority: .userInitiated) {
                        guard existingCount + urls.count <= limits.maxImagesPerMessage else {
                            throw AttachmentImportError.tooMany(limits.maxImagesPerMessage)
                        }
                        var totalBytes = existingBytes
                        for url in urls {
                            let hasScope = url.startAccessingSecurityScopedResource()
                            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                            guard size <= limits.maxImageBytes else {
                                throw AttachmentImportError.tooLarge(url.lastPathComponent, limits.maxImageBytes)
                            }
                            totalBytes += size
                        }
                        guard totalBytes <= limits.maxMessageImageBytes else {
                            throw AttachmentImportError.totalTooLarge(limits.maxMessageImageBytes)
                        }
                        return try urls.map { url -> HarnessAttachment in
                            let hasScope = url.startAccessingSecurityScopedResource()
                            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                            let ext = url.pathExtension.lowercased()
                            let mimeTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                             "gif": "image/gif", "webp": "image/webp"]
                            guard let mimeType = mimeTypes[ext],
                                  let type = UTType(filenameExtension: ext), type.conforms(to: .image) else {
                                throw AttachmentImportError.unsupportedType(url.lastPathComponent)
                            }
                            let data = try Data(contentsOf: url, options: .mappedIfSafe)
                            return HarnessAttachment(name: url.lastPathComponent, mimeType: mimeType, data: data)
                        }
                    }.value
                    pendingAttachments.append(contentsOf: attachments)
                    attachmentError = nil
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Slash commands (the DSH input trigger)

    /// The draft's leading `/token` while it is still a bare token. This is
    /// the DSH `ui-input-trigger` shape: the menu opens for a leading trigger
    /// and closes once the token is followed by whitespace.
    private var slashToken: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.dropFirst().contains(where: { $0.isWhitespace }) else { return nil }
        return String(trimmed.dropFirst())
    }

    /// Esc dismissed the menu but the token is still in the draft; any edit
    /// re-opens it (official `dismissPopup` never deletes the typed line).
    private var slashMenuVisible: Bool { slashToken != nil && !slashMenuDismissed }

    /// Official `rankByName`: case-insensitive subsequence match over the row's
    /// registered name and its localized label, ranked by prefix, word
    /// boundary and adjacency; the catalog's descriptions never match.
    private var slashMatches: [NativeCommandDescriptor] {
        guard let token = slashToken else { return [] }
        let query = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = model.availableCommands
        guard !query.isEmpty else { return Array(commands.prefix(8)) }
        let ranked: [(score: Int, index: Int, descriptor: NativeCommandDescriptor)] = commands.enumerated().compactMap { index, descriptor in
            let scores = [
                Self.commandMatchScore(query, descriptor.name),
                Self.commandMatchScore(query, NativeCommandCatalog.title(for: descriptor)),
            ].compactMap { $0 }
            guard let best = scores.max() else { return nil }
            return (best, index, descriptor)
        }
        return ranked.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .prefix(8).map(\.descriptor)
    }

    /// 0 when the query is not a subsequence; otherwise the alignment score
    /// (prefix > separator boundary > adjacency > gap).
    static func commandMatchScore(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }
        var score = 0
        var cursor = 0
        var previous: Int?
        var matchedFirst = false
        for character in needle {
            var found: Int?
            while cursor < haystack.count {
                if haystack[cursor] == character { found = cursor; break }
                cursor += 1
            }
            guard let index = found else { return nil }
            if !matchedFirst {
                matchedFirst = true
                if index == 0 { score += 100 }
            }
            if index == 0 || !haystack[index - 1].isLetter && !haystack[index - 1].isNumber {
                score += 10
            }
            if let previous, index == previous + 1 { score += 5 }
            score -= index - (previous.map { $0 + 1 } ?? 0)
            previous = index
            cursor = index + 1
        }
        return score
    }

    /// The command menu: one 指令 section of live catalog rows, each with the
    /// official localized face, its alias and the right-aligned description.
    @ViewBuilder
    private var slashCommandMenu: some View {
        let matches = slashMatches
        VStack(alignment: .leading, spacing: 0) {
            if model.commandsLoading && model.availableCommands.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取 DSH 命令…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(12)
            } else if let error = model.commandsError, model.availableCommands.isEmpty {
                HStack(spacing: 8) {
                    Text(error).font(.system(size: 13)).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("重试") { Task { await model.loadCommands() } }
                        .font(.system(size: 13))
                }
                .padding(12)
            } else if matches.isEmpty {
                Text("没有匹配的命令").font(.system(size: 13))
                    .foregroundStyle(.secondary).padding(12)
            } else {
                Text("指令")
                    .font(.system(size: 11))
                    .foregroundStyle(NativeChatTheme.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
                    .padding(.bottom, 2)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, descriptor in
                                slashCommandRow(descriptor, highlighted: index == slashHighlight)
                                    .id(descriptor.id)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .scrollIndicators(.hidden)
                    .onChange(of: slashHighlight) { _, value in
                        guard value < matches.count else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(matches[value].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomeSpec.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("指令")
        .onChange(of: slashToken) { _, _ in
            slashHighlight = 0
        }
    }

    /// One menu row: icon, localized title, the registered alias when the title
    /// is a translation, and the description right-aligned (official
    /// `MenuView.tsx` row anatomy).
    private func slashCommandRow(_ descriptor: NativeCommandDescriptor, highlighted: Bool) -> some View {
        let title = NativeCommandCatalog.title(for: descriptor)
        return Button {
            pickCommand(descriptor)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: NativeCommandCatalog.icon(for: descriptor))
                    .font(.system(size: 14))
                    .foregroundStyle(highlighted ? NativeChatTheme.secondary : NativeChatTheme.tertiary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(NativeChatTheme.primary)
                    .lineLimit(1)
                if descriptor.name.lowercased() != title.lowercased() {
                    Text(descriptor.name)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeChatTheme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(NativeCommandCatalog.description(for: descriptor))
                    .font(.system(size: 12))
                    .foregroundStyle(NativeChatTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(highlighted ? NativeChatTheme.selector : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) /\(descriptor.name)")
        .accessibilityHint(NativeCommandCatalog.description(for: descriptor))
    }

    /// Official menu pick: a command that declares an input claim writes its
    /// localized token into the draft and waits for arguments; every other
    /// command runs detached on the bare pick.
    private func pickCommand(_ descriptor: NativeCommandDescriptor) {
        slashMenuDismissed = true
        slashHighlight = 0
        if descriptor.hasInput {
            let token = NativeCommandCatalog.face(for: descriptor)?.token ?? descriptor.name
            draft = "/\(token) "
            inputFocused = true
            return
        }
        draft = ""
        Task { await executeCommand(descriptor, input: "", attachments: pendingAttachments) }
    }

    private var referenceToken: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"), !trimmed.dropFirst().contains(where: { $0.isWhitespace }) else { return nil }
        return String(trimmed.dropFirst())
    }

    private var referenceFiles: [WorkspaceFile] {
        guard let token = referenceToken else { return [] }
        return model.files.filter { token.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(token) }.prefix(6).map { $0 }
    }

    private var referenceSessions: [ManagedSession] {
        guard let token = referenceToken, !token.isEmpty else { return [] }
        return management.sessions.filter { $0.title.localizedCaseInsensitiveContains(token) }.prefix(3).map { $0 }
    }

    @ViewBuilder
    private var referenceMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            if referenceFiles.isEmpty && referenceSessions.isEmpty {
                Text("没有匹配的文件或对话")
                    .font(NativeChatTheme.secondaryFont())
                    .foregroundStyle(NativeChatTheme.secondary)
                    .padding(12)
            } else {
                ForEach(referenceFiles) { file in
                    Button {
                        draft = file.relativePath + " "
                        inputFocused = true
                    } label: {
                        HStack(spacing: 10) {
                            FileTypeGlyph.icon(for: file.relativePath, size: 20)
                            Text(file.relativePath).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(referenceSessions) { session in
                    Button {
                        draft = "@\(session.title) "
                        inputFocused = true
                    } label: {
                        HStack(spacing: 10) {
                            NativeChatIcon(name: .branch, size: 16)
                            Text(session.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(NativeChatTheme.secondaryFont())
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeChatTheme.selector, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    static func parseSlashCommand(_ text: String) -> (name: String, input: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }
        let input = body.dropFirst(name.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(name), input)
    }

    /// Resolve a typed line the way official `resolveCommand` does (registered
    /// name, then the localized spelling of a known definition) and execute the
    /// canonical command. A refusal keeps the line in the draft for correction.
    private func runSlashCommand(name: String, input: String) async {
        let line = "/\(name)" + (input.isEmpty ? "" : " \(input)")
        guard let descriptor = NativeCommandCatalog.resolve(name, in: model.availableCommands) else {
            composerNotice = ComposerNotice(level: .error, text: "没有这条命令：/\(name)")
            if draft.isEmpty { draft = line }
            return
        }
        guard pendingAttachments.isEmpty || descriptor.acceptsAttachments else {
            composerNotice = ComposerNotice(level: .error,
                                            text: NativeCommandCatalog.attachmentRefusal(for: descriptor.name))
            if draft.isEmpty { draft = line }
            return
        }
        await executeCommand(descriptor, input: input, attachments: pendingAttachments)
    }

    // MARK: - Workspace file import (DSH file attachments)

    /// Imports the picked files into the session workspace through the
    /// Worker's `phone/import*` service (the phone DSH path for a verbatim
    /// file: the prompt API accepts images only, budget §A.5's analogue is the
    /// workspace), then inserts their path so the agent can read them.
    private func loadWorkspaceFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentError = "无法读取所选文件：\(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            guard let sessionID = model.currentSessionID else {
                attachmentError = "本地引擎还没启动，启动之后才能把文件放进工作区。"
                return
            }
            Task { await importIntoWorkspace(urls, sessionID: sessionID) }
        }
    }

    private func importIntoWorkspace(_ urls: [URL], sessionID: String) async {
        // The Worker's directory-import contract: 64 MiB per file, 128 MiB and
        // 500 files per import (plugins/phone-directory-import).
        let maxFileBytes = 64 * 1024 * 1024
        let maxTotalBytes = 128 * 1024 * 1024
        let chunkBytes = 1024 * 1024
        do {
            var files: [WebEngineDirectoryImportFile] = []
            var payloads: [(path: String, data: Data)] = []
            var total = 0
            for url in urls {
                let hasScope = url.startAccessingSecurityScopedResource()
                defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                guard !name.isEmpty, !name.contains("/") else {
                    throw AttachmentImportError.unsupportedType(name)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                    as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= maxFileBytes else {
                    throw ImportFailure.tooLarge(name, size)
                }
                total += size
                guard total <= maxTotalBytes else { throw ImportFailure.totalTooLarge }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                files.append(WebEngineDirectoryImportFile(path: name, size: data.count))
                payloads.append((path: name, data: data))
            }
            let stamp = Self.importTimestamp()
            let manifest = WebEngineDirectoryImportManifest(
                sessionID: sessionID,
                targetDirectory: "/dsh/workspace",
                entryName: "files-\(stamp)",
                directories: [],
                files: files,
                totalBytes: total)
            let transport = try await model.transportForManagement()
            let sink = PhoneDSHWorkspaceImportSink(transport: transport)
            let importID = try await sink.begin(manifest)
            for payload in payloads {
                var offset = 0
                while offset < payload.data.count {
                    let end = min(offset + chunkBytes, payload.data.count)
                    try await sink.write(importID: importID, path: payload.path,
                                         offset: offset,
                                         data: payload.data.subdata(in: offset..<end))
                    offset = end
                }
            }
            let result = try await sink.commit(importID: importID)
            let reference = files.count == 1
                ? "\(result.workspacePath)/\(files[0].path)"
                : "\(result.workspacePath)/"
            fileImportNotice = "已写入工作区：\(reference)"
            let separator = draft.isEmpty ? "" : "\n"
            draft += "\(separator)\(reference)\n"
            inputFocused = true
        } catch {
            attachmentError = "导入失败：\(error.localizedDescription)"
        }
    }

    private static func importTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private enum ImportFailure: LocalizedError {
        case tooLarge(String, Int)
        case totalTooLarge

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name, let size):
                return "\(name) 超过 64 MiB（\(size) 字节）。"
            case .totalTooLarge:
                return "一次最多导入 128 MiB。"
            }
        }
    }

    private var historyExport: String {
        let lines = model.items.compactMap { item -> String? in
            guard item.kind != .status else { return nil }
            return "### \(exportTitle(item))\n\n\(item.text)"
        }
        var document = ["# \(sessionTitle)"]
        document.append(contentsOf: lines)
        return document.joined(separator: "\n\n")
    }

    private func exportTitle(_ item: ChatItem) -> String {
        switch item.title {
        case "You": "你"
        case "You (steering)": "你（补充说明）"
        case "Assistant": "DSH"
        case let title where title.hasPrefix("DSH context · "):
            NativeSourceName.chinese(title.replacingOccurrences(of: "DSH context · ", with: ""))
                .map { "上下文注入 · \($0)" } ?? "上下文注入"
        case "Tool result": "工具结果"
        case "Tool error": "工具错误"
        default:
            item.title.hasPrefix("Tool call: ")
                ? "工具调用 · " + item.title.replacingOccurrences(of: "Tool call: ", with: "")
                : item.title
        }
    }

    private func savedDraft(for key: String) -> String {
        guard let data = savedDrafts.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return values[key] ?? ""
    }

    private func persistDraft(_ value: String, for key: String) {
        guard !key.isEmpty else { return }
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(savedDrafts.utf8))) ?? [:]
        values[key] = value
        if let data = try? JSONEncoder().encode(values), let string = String(data: data, encoding: .utf8) {
            savedDrafts = string
        }
    }
}

private enum AttachmentImportError: LocalizedError {
    case unsupportedType(String)
    case tooLarge(String)
    case tooMany(Int)
    case tooLarge(String, Int)
    case totalTooLarge(Int)
    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name): return "不支持的图片格式：\(name)。请选 PNG、JPEG、GIF 或 WebP。"
        case .tooLarge(let name, let bytes):
            return "图片过大：\(name) 超过单张 \(Self.megabytes(bytes)) MB 的上限。"
        case .tooMany(let count): return "一次最多添加 \(count) 张图片。"
        case .totalTooLarge(let bytes): return "所选图片合计超过 \(Self.megabytes(bytes)) MB，请分批发送。"
        }
    }
    private static func megabytes(_ bytes: Int) -> Int {
        max(1, (bytes + 1024 * 1024 - 1) / (1024 * 1024))
    }
}

/// One composer notice line (official `InputBar` notice channel).
private struct ComposerNotice: Equatable {
    enum Level: Equatable { case info, error }
    let level: Level
    let text: String
}

/// A hardware-keyboard gesture the slash menu arbitrates.
private enum ComposerMenuKey {
    case up, down, tab, escape
}

/// The composer's editable surface.
///
/// A `TextEditor` can only insert a newline on Return: the phone keyboard shows
/// "return", Return never sends, ⌘/Ctrl+Return cannot be told apart, and Esc/
/// arrow keys never reach the open command menu. The official composer sends on
/// Return, keeps Shift+Return as a line break, uses ⌘/Ctrl+Return for the
/// opposite busy-Enter delivery and routes ↑/↓/Tab/Esc to the menu
/// (`ui-conversation/src/client/input/editor/keymap.ts:77-158`), which on iOS
/// only exists below SwiftUI in a `UITextView`.
private struct NativeComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEditable: Bool
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var maxHeight: CGFloat
    var menuOpen: Bool
    var accessibilityLabel: String
    /// Return/Enter; `accelerated` is ⌘/Ctrl+Return. True consumes the gesture,
    /// false lets a newline through.
    var onReturn: (_ accelerated: Bool) -> Bool
    /// ↑/↓/Tab/Esc arbitration; true consumes the key.
    var onMenuKey: (_ key: ComposerMenuKey) -> Bool
    var onHeightChange: (_ height: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        // Scrolling stays on for the view's whole life: a non-scrolling
        // UITextView reports its *content* height as its intrinsic size, which
        // SwiftUI then lays out past the card. The composer measures the laid
        // out text and hands SwiftUI the clamped height instead (official
        // InputBar caps the scrollport at 336 and scrolls inside).
        view.clipsToBounds = true
        view.isScrollEnabled = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 5
        // The software keyboard's action key says 发送, like `enterkeyhint=send`
        // on the web bar (`ui-mobile/src/client/mobile-enter-send.ts`).
        view.returnKeyType = .send
        view.keyboardDismissMode = .interactive
        view.autocapitalizationType = .sentences
        view.text = text
        view.font = UIFont.systemFont(ofSize: fontSize)
        view.accessibilityLabel = accessibilityLabel
        let coordinator = context.coordinator
        coordinator.attach(view)
        view.onMenuKey = { [weak coordinator] key in coordinator?.parent.onMenuKey(key) ?? false }
        view.onAcceleratedReturn = { [weak coordinator] in coordinator?.parent.onReturn(true) ?? false }
        view.onLineBreak = { [weak coordinator] in coordinator?.insertLineBreak() ?? false }
        view.onLayout = { [weak coordinator] in coordinator?.reportHeight() }
        return view
    }

    /// SwiftUI asks the representable for its size; without this it would use
    /// the text view's content-driven intrinsic height and the composer would
    /// grow past the card.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.measuredHeight(for: width))
    }

    func updateUIView(_ uiView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        let coordinator = context.coordinator
        if uiView.text != text, !coordinator.isApplyingText {
            coordinator.isApplyingText = true
            uiView.text = text
            // An external edit (menu pick, import path, restored draft) puts
            // the caret at the end; a local keystroke never reaches this path.
            let end = uiView.endOfDocument
            uiView.selectedTextRange = uiView.textRange(from: end, to: end)
            coordinator.isApplyingText = false
        }
        uiView.isEditable = isEditable
        uiView.returnKeyType = .send
        uiView.menuOpen = menuOpen
        uiView.accessibilityLabel = accessibilityLabel
        if uiView.font?.pointSize != fontSize {
            uiView.font = UIFont.systemFont(ofSize: fontSize)
        }
        coordinator.applyTypingAttributes(lineSpacing: lineSpacing)
        if isFocused, !uiView.isFirstResponder, uiView.window != nil {
            // The hop exists so the view is in a window before it becomes first
            // responder. It must re-read the *current* intent when it runs: a
            // send releases focus in the same turn that queued this block, and
            // the queued becomeFirstResponder used to run afterwards, see a view
            // that is no longer first responder, and bring the keyboard back.
            ComposerFocusRequest.schedule(
                isCurrent: { [weak uiView, weak coordinator] in
                    guard let uiView, uiView.window != nil else { return false }
                    return !uiView.isFirstResponder && coordinator?.parent.isFocused == true
                },
                focus: { [weak uiView] in uiView?.becomeFirstResponder() })
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        coordinator.reportHeight()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeComposerTextView
        var isApplyingText = false
        private var lastHeight: CGFloat = 0
        /// Set while a Shift+Return newline is being inserted through the key
        /// command, so the delegate lets that one newline through.
        private var insertingLineBreak = false

        init(_ parent: NativeComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingText else { return }
            parent.text = textView.text
            reportHeight()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            guard text == "\n" || text == "\r" else { return true }
            if insertingLineBreak {
                insertingLineBreak = false
                return true
            }
            // An IME candidate pick is not a submit (official guards the
            // composition-close Enter).
            if textView.markedTextRange != nil { return true }
            return !parent.onReturn(false)
        }

        func insertLineBreak() -> Bool {
            guard let textView = lastTextView else { return false }
            insertingLineBreak = true
            textView.insertText("\n")
            // `insertText` may not consult the delegate on every OS; never
            // leave the flag latched.
            DispatchQueue.main.async { [weak self] in self?.insertingLineBreak = false }
            return true
        }

        /// The view is owned by SwiftUI; the coordinator only observes it so a
        /// key command or a text edit can measure it.
        private weak var lastTextView: ComposerUITextView?

        func attach(_ textView: ComposerUITextView) { lastTextView = textView }

        private var lastTyping: (fontSize: CGFloat, lineSpacing: CGFloat)?

        /// Apply the composer's paragraph style once per font/spacing change;
        /// SwiftUI re-runs `updateUIView` on every keystroke.
        func applyTypingAttributes(lineSpacing: CGFloat) {
            guard let textView = lastTextView else { return }
            let fontSize = parent.fontSize
            if let last = lastTyping, last.fontSize == fontSize, last.lineSpacing == lineSpacing { return }
            lastTyping = (fontSize, lineSpacing)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = max(0, lineSpacing)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraph,
                .foregroundColor: UIColor.label,
            ]
            textView.typingAttributes = attributes
            guard textView.textStorage.length > 0 else { return }
            textView.textStorage.beginEditing()
            textView.textStorage.setAttributes(attributes,
                                               range: NSRange(location: 0, length: textView.textStorage.length))
            textView.textStorage.endEditing()
        }

        /// Height of the laid-out text plus the composer's text insets, clamped
        /// to the official 36…336 scrollport.
        func measuredHeight(for width: CGFloat) -> CGFloat {
            guard let textView = lastTextView else { return 36 }
            let container = textView.textContainer
            container.size = CGSize(width: max(0, width - 2 * textView.textContainerInset.left),
                                    height: .greatestFiniteMagnitude)
            let layout = textView.layoutManager
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let content = used + textView.textContainerInset.top + textView.textContainerInset.bottom
            return min(max(ceil(content), 36), parent.maxHeight)
        }

        func reportHeight() {
            guard let textView = lastTextView else { return }
            let width = textView.bounds.width
            guard width > 0 else { return }
            let height = measuredHeight(for: width)
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in
                self?.parent.onHeightChange(height)
            }
        }
    }
}

/// `UITextView` with the composer's key commands: Return is intercepted by the
/// delegate; ⌘/Ctrl+Return asks for the accelerated delivery; Shift+Return
/// inserts a line break; ↑/↓/Tab are menu keys only while the menu is open, so
/// they keep their native meaning otherwise; Esc always routes (menu first,
/// then stop).
private final class ComposerUITextView: UITextView {
    var onMenuKey: ((ComposerMenuKey) -> Bool)?
    var onAcceleratedReturn: (() -> Bool)?
    var onLineBreak: (() -> Bool)?
    var onLayout: (() -> Void)?
    var menuOpen = false

    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onLayout?()
        }
    }

    /// Never let the text content drive the view's size: the composer
    /// measures it and hands SwiftUI the clamped height.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        let accelerated = UIKeyCommand(input: "\r", modifierFlags: .command,
                                       action: #selector(handleAcceleratedReturn))
        accelerated.wantsPriorityOverSystemBehavior = true
        let control = UIKeyCommand(input: "\r", modifierFlags: .control,
                                   action: #selector(handleAcceleratedReturn))
        control.wantsPriorityOverSystemBehavior = true
        let shift = UIKeyCommand(input: "\r", modifierFlags: .shift,
                                 action: #selector(handleShiftReturn))
        shift.wantsPriorityOverSystemBehavior = true
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                                  action: #selector(handleMenuKeyCommand(_:)))
        escape.wantsPriorityOverSystemBehavior = true
        commands.append(contentsOf: [accelerated, control, shift, escape])
        if menuOpen {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\t"] {
                let command = UIKeyCommand(input: input, modifierFlags: [],
                                           action: #selector(handleMenuKeyCommand(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }

    @objc private func handleAcceleratedReturn() {
        _ = onAcceleratedReturn?()
    }

    @objc private func handleShiftReturn() {
        _ = onLineBreak?()
    }

    @objc private func handleMenuKeyCommand(_ command: UIKeyCommand) {
        let key: ComposerMenuKey
        switch command.input {
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        case "\t": key = .tab
        case UIKeyCommand.inputEscape: key = .escape
        default: return
        }
        _ = onMenuKey?(key)
    }
}

/// Reports whether the person is driving the transcript scroll (dragging or
/// coasting after a flick), as opposed to code scrolling it.
private struct ScrollInteractionObserver: ViewModifier {
    @Binding var isInteracting: Bool
    @Binding var isSupported: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    isInteracting = phase == .interacting || phase == .decelerating
                }
                .onAppear { isSupported = true }
        } else {
            content
        }
    }
}

/// Holds the last measured tail offset for the scroll diagnostic without
/// invalidating the transcript view on every scroll frame.
final class ScrollTraceBox {
    var tailOffsetY: CGFloat = 0
}

private struct TranscriptTailPreference: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Full transcript height, so a "scroll to the tail" is skipped when the
/// content already fits the viewport: a bottom-anchored scroll on a shorter
/// transcript overshoots into empty space and reads as a blank page.
private struct TranscriptContentHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct QuestionCard: View {
    let question: HarnessQuestion
    let submit: (String) -> Void

    @State private var singleSelections: [String: String] = [:]
    @State private var multipleSelections: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]

    private var questions: [HarnessQuestionItem] {
        if let questions = question.questions, !questions.isEmpty { return questions }
        return [HarnessQuestionItem(id: "answer", prompt: question.prompt, options: question.options)]
    }

    private var canSubmit: Bool {
        questions.allSatisfy { item in
            let custom = customAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if item.multiple {
                return !(multipleSelections[item.id, default: []].isEmpty && custom.isEmpty)
            }
            return singleSelections[item.id] != nil || !custom.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("需要你的回答", systemImage: "questionmark.circle.fill")
                .font(.headline)
            if let items = question.questions, !items.isEmpty, !question.prompt.isEmpty {
                Text(question.prompt).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(questions) { item in
                questionControl(item)
            }
            Button("提交回答", systemImage: "arrow.up") { submitAnswers() }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.09))
    }

    @ViewBuilder
    private func questionControl(_ item: HarnessQuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.prompt).font(.subheadline.weight(.semibold))
            ForEach(item.options, id: \.self) { option in
                let selected = item.multiple
                    ? multipleSelections[item.id, default: []].contains(option)
                    : singleSelections[item.id] == option
                Button {
                    if item.multiple {
                        if selected { multipleSelections[item.id, default: []].remove(option) }
                        else { multipleSelections[item.id, default: []].insert(option) }
                    } else {
                        singleSelections[item.id] = option
                        customAnswers[item.id] = ""
                    }
                } label: {
                Label(option, systemImage: selected
                          ? (item.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                          : (item.multiple ? "square" : "circle"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(minHeight: 44, alignment: .leading)
            }
            TextField(item.options.isEmpty ? "输入回答" : "其他回答", text: binding(for: item.id))
                .textFieldStyle(.roundedBorder)
                .onChange(of: customAnswers[item.id, default: ""]) { _, value in
                    if !value.isEmpty && !item.multiple { singleSelections[item.id] = nil }
                }
            if item.multiple {
                Text("可多选，也可以补充自定义回答。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { customAnswers[id, default: ""] }, set: { customAnswers[id] = $0 })
    }

    private func submitAnswers() {
        var values: [String: Any] = [:]
        for item in questions {
            let custom = customAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if item.multiple {
                var selected = item.options.filter { multipleSelections[item.id, default: []].contains($0) }
                if !custom.isEmpty { selected.append(custom) }
                values[item.id] = selected
            } else {
                values[item.id] = singleSelections[item.id] ?? (custom.isEmpty ? "" : custom)
            }
        }
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let answer = String(data: data, encoding: .utf8) else { return }
        submit(answer)
    }
}

private struct NativeScheduleListSheet: View {
    let schedules: [ManagedSchedule]
    var onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if schedules.isEmpty {
                    ContentUnavailableView("没有定时任务",
                                           systemImage: "calendar.badge.clock",
                                           description: Text("这个会话暂时没有定时任务。"))
                        .listRowSeparator(.hidden)
                }
                ForEach(schedules) { schedule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(schedule.title)
                                .font(.system(size: HomeSpec.bodySize, weight: .medium))
                                .foregroundStyle(HomeSpec.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            HomeTag(text: schedule.status)
                        }
                        Text(schedule.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                        Text(schedule.prompt)
                            .font(.system(size: 14))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 6)
                }
            }
            .homeGroupedList()
            .navigationTitle("定时任务")
            .navigationBarTitleDisplayMode(.inline)
            // Half-height sheet: an outside tap closes it, so no close
            // button; refresh is the only bar action, on the leading side.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新", systemImage: "arrow.clockwise") { onRefresh() }
                }
            }
        }
    }
}

private struct NativeJobListSheet: View {
    let jobs: [ActivityRow]
    var onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if jobs.isEmpty {
                    ContentUnavailableView("没有后台任务",
                                           systemImage: "list.bullet",
                                           description: Text("这个会话暂时没有后台任务。"))
                        .listRowSeparator(.hidden)
                }
                ForEach(jobs) { job in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title)
                                .font(.system(size: HomeSpec.bodySize, weight: .medium))
                                .foregroundStyle(HomeSpec.textPrimary)
                                .lineLimit(1)
                            Text(job.detail)
                                .font(.system(size: 13))
                                .foregroundStyle(HomeSpec.textPlaceholder)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let status = job.status {
                            HomeTag(text: status)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .homeGroupedList()
            .navigationTitle("后台任务")
            .navigationBarTitleDisplayMode(.inline)
            // Half-height sheet: an outside tap closes it, so no close
            // button; refresh is the only bar action, on the leading side.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新", systemImage: "arrow.clockwise") { onRefresh() }
                }
            }
        }
    }
}

private struct NativePlanPreview: Identifiable {
    let id: String
    let title: String
    let markdown: String
}

private struct ChatMessageRow: View {
    let item: ChatItem
    let allItems: [ChatItem]
    var workspaceFiles: [WorkspaceFile]
    var onOpenFile: (String) -> Void
    var onOpenPlan: (NativePlanCardData, String) -> Void = { _, _ in }

    var body: some View {
        switch item.kind {
        case .toolCall, .toolResult:
            NativeToolCallRow(item: item, onOpenFile: onOpenFile)
        case .context:
            if item.sourceKind == "user-question-reply" {
                // Late reply to a continued ask_user_question: the official
                // right-aligned question-reply bubble, not a raw trigger row.
                NativeQuestionReplyBubble(reply: NativeQuestionReply(
                    id: item.id,
                    callID: item.callID ?? "",
                    time: item.timestamp ?? Date(),
                    questions: [],
                    answers: [],
                    fallbackText: item.text))
            } else if let source = item.sourceKind {
                // A non-human producer that surfaced through user/message or
                // inbox/spliced: the official turn-trigger notice, not a raw
                // context injection.
                NativeTurnTriggerRow(data: NativeTurnTriggerData(
                    source: NativeTurnTriggerSource.resolve(kind: source),
                    time: item.timestamp,
                    content: item.text))
            } else {
                ContextInjectionCard(item: item)
            }
        case .user:
            // Home: the bubble alone, no action row under it; copying stays
            // on the bubble's context menu.
            VStack(alignment: .trailing, spacing: 8) {
                userBubble
                    .contextMenu {
                        if !item.text.isEmpty {
                            Button("复制", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = item.text
                            }
                            ShareLink(item: item.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                    }
                if !item.attachments.isEmpty { NativeAttachmentList(attachments: item.attachments, onOpenFile: onOpenFile) }
            }
        case .assistant:
            assistantBody
                .contextMenu {
                    if !item.text.isEmpty {
                        Button("复制全文", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = item.text
                        }
                    }
                }
        case .reasoning:
            NativeThinkingRow(item: item)
        case .image:
            NativeAttachmentList(attachments: item.attachments, onOpenFile: onOpenFile)
        case .systemEvent, .turnError, .maxTokens:
            NativeSystemEventRow(item: item)
        case .unknown:
            DSHJsonBlock(text: item.text)
        case .status:
            EmptyView()
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeMarkdownBody(markdown: item.text.isEmpty ? "…" : item.text,
                               streaming: item.streaming, workspaceFiles: workspaceFiles,
                               onOpenFile: onOpenFile)
                .font(NativeChatTheme.bodyFont())
                // Official assistant body is 14/24; SwiftUI's default leading
                // is ~17, so add the official 10px leading delta explicitly.
                .lineSpacing(NativeChatTheme.bodyLineSpacing)
                .environment(\.openURL, OpenURLAction { url in
                    guard let path = workspaceRelativePath(from: url) else { return .systemAction }
                    onOpenFile(path)
                    return .handled
                })
            if isTurnClosingAssistant, let turn = item.turn {
                if let changes = NativeTranscriptProjector.changes(forTurn: turn, in: allItems) {
                    NativeChangedFilesCard(changes: changes, onOpenFile: onOpenFile)
                }
                if !submittedPlans.isEmpty {
                    VStack(alignment: .leading, spacing: NativePlanCard.stackSpacing) {
                        ForEach(submittedPlans, id: \.0.id) { plan, markdown in
                            NativePlanCard(plan: plan) {
                                onOpenPlan(plan, markdown)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isTurnClosingAssistant: Bool {
        guard let turn = item.turn, !item.streaming else { return false }
        return allItems.last(where: { $0.turn == turn && $0.kind == .assistant })?.id == item.id
    }

    /// Official `submitted-plan` nodes: every `exit_plan_mode` call whose args
    /// carry a `# ` headed plan, in invocation order for this Turn.
    private var submittedPlans: [(NativePlanCardData, String)] {
        guard let turn = item.turn else { return [] }
        return allItems.compactMap { row in
            guard row.turn == turn, row.toolName == "exit_plan_mode",
                  let markdown = row.arguments?["plan"]?.stringValue,
                  let plan = NativePlanCardData(id: row.callID ?? row.id, markdown: markdown)
            else { return nil }
            return (plan, markdown)
        }
    }

    private static func assistantText(forTurn turn: Int, in items: [ChatItem]) -> String {
        items.filter { $0.turn == turn && $0.kind == .assistant }.map(\.text).joined(separator: "\n\n")
    }

    /// 贴字优先:能一行放下就用自然宽度,放不下才在内容宽度的 80% 内换行。
    /// 灰底 16/24,内边距 12·16,圆角 24、右上角直角(HomeSpec)。
    private var userBubble: some View {
        let body = Text(item.text.isEmpty ? "…" : item.text)
            .font(NativeChatTheme.bodyFont())
            .lineSpacing(NativeChatTheme.bodyLineSpacing)
            .foregroundStyle(HomeSpec.textPrimary)
            .textSelection(.enabled)
        return ViewThatFits(in: .horizontal) {
            body.fixedSize(horizontal: true, vertical: true)
            body
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(HomeSpec.userBubble, in: HomeSpec.bubbleShape)
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
            (width - 2 * HomeSpec.contentInset) * 0.8
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

}

/// Shared with the Bot page, which draws its tool steps the same way.
struct ToolRunRow: View {
    let items: [ChatItem]
    var workspaceFiles: [WorkspaceFile] = []
    var onOpenFile: (String) -> Void = { _ in }
    @State private var expanded = true
    @State private var scrollMetrics = ProcessScrollMetrics()
    @State private var displayedTitle = ""
    @State private var titleTask: Task<Void, Never>?

    private var targetTitle: String {
        NativeProcessGroupModel.title(for: categories, running: isRunning)
    }

    private var processViewport: CGFloat {
        min(400, UIScreen.main.bounds.height * 0.5)
    }

    private var showTopFade: Bool { scrollMetrics.offset < -4 }
    private var showBottomFade: Bool {
        scrollMetrics.contentHeight + scrollMetrics.offset > processViewport + 4
    }

    private var categories: [NativeProcessCategory] {
        items.map {
            $0.kind == .reasoning ? .thinking : NativeProcessCategory.forTool($0.toolName ?? "")
        }
    }

    private var isRunning: Bool {
        items.contains { $0.toolState == .running || $0.toolState == .preparing }
    }

    var body: some View {
        // The official group header already carries the 8pt expanded gap;
        // its body members own the 6pt flow gap. Do not add a VStack gap
        // between the header and the first member (that would make 14pt).
        VStack(alignment: .leading, spacing: 0) {
            if items.count > 1 {
                NativeProcessGroupHeader(
                    title: displayedTitle.isEmpty ? targetTitle : displayedTitle,
                    glyph: categories.first?.glyph ?? .tools,
                    isRunning: isRunning,
                    isExpanded: expanded) {
                        withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                    }
            }
            if expanded || items.count == 1 {
                if items.count > 4 {
                    ScrollView {
                        processRows
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ProcessScrollMetricsKey.self,
                                    value: ProcessScrollMetrics(
                                        offset: geometry.frame(in: .named("process-scroll")).minY,
                                        contentHeight: geometry.size.height))
                            })
                    }
                    .coordinateSpace(name: "process-scroll")
                    .onPreferenceChange(ProcessScrollMetricsKey.self) { scrollMetrics = $0 }
                    .scrollIndicators(.visible)
                    .frame(maxHeight: processViewport)
                    .overlay(alignment: .top) {
                        if showTopFade { processFade(top: true) }
                    }
                    .overlay(alignment: .bottom) {
                        if showBottomFade { processFade(top: false) }
                    }
                } else {
                    processRows
                }
            }
        }
        .onAppear { displayedTitle = targetTitle }
        .onChange(of: targetTitle) { _, next in
            titleTask?.cancel()
            if isRunning {
                titleTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    displayedTitle = next
                }
            } else {
                displayedTitle = next
            }
        }
        .onDisappear { titleTask?.cancel() }
    }

    /// An opened group sits in the white list card (HomeSpec): rows 8pt
    /// apart inside 8·12 padding. A lone call stays a bare row.
    @ViewBuilder
    private var processRows: some View {
        let rows = VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                if item.kind == .reasoning {
                    NativeThinkingRow(item: item)
                } else {
                    NativeToolCallRow(item: item, onOpenFile: onOpenFile)
                }
            }
        }
        if items.count > 1 {
            rows.homeListCard()
        } else {
            rows
        }
    }

    private func processFade(top: Bool) -> some View {
        LinearGradient(
            colors: [HomeSpec.page, HomeSpec.page.opacity(0)],
            startPoint: top ? .top : .bottom,
            endPoint: top ? .bottom : .top)
            .frame(height: 24)
            .allowsHitTesting(false)
    }
}

private struct ProcessScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct ProcessScrollMetricsKey: PreferenceKey {
    static var defaultValue = ProcessScrollMetrics()
    static func reduce(value: inout ProcessScrollMetrics, nextValue: () -> ProcessScrollMetrics) {
        value = nextValue()
    }
}

private struct ContextInjectionCard: View {
    let item: ChatItem
    @State private var expanded = false

    private var sourceName: String {
        item.title.replacingOccurrences(of: "DSH context · ", with: "")
    }

    private var summary: String {
        let firstLine = item.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "DSH 为本轮注入的上下文"
        return String(firstLine.prefix(180))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView([.horizontal, .vertical]) {
                Text(item.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 360)
        } label: {
            // 上下文行同工具行:一行提示,不加底色卡片;箭头表示能点开。
            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                Text("上下文注入 · \(sourceName)")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
    }
}

private struct TraceStatusRow: View {
    let item: ChatItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "circle.inset.filled")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title == "Host" ? "主机事件" : item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct MarkdownContent: View {
    let text: String
    var onOpenFile: (String) -> Void = { _ in }

    private enum Block {
        case markdown(String)
        case code(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var markdown = ""
        var code: String?
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let current = code {
                    result.append(.code(current))
                    code = nil
                } else {
                    if !markdown.isEmpty { result.append(.markdown(markdown)); markdown = "" }
                    code = ""
                }
                continue
            }
            if code != nil { code!.append(line + "\n") }
            else { markdown.append(line + "\n") }
        }
        if let code { result.append(.code(code)) }
        if !markdown.isEmpty { result.append(.markdown(markdown)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let source):
                    if let attributed = try? AttributedString(markdown: source) {
                        Text(attributed)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.openURL, OpenURLAction { url in
                                guard let path = workspaceRelativePath(from: url) else { return .systemAction }
                                onOpenFile(path)
                                return .handled
                            })
                    } else {
                        Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let source):
                    DSSCodeBlock(source: source)
                }
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 图标和文字之间固定 6。
private struct IconTextGap: LabelStyle {
    let gap: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: gap) {
            configuration.icon
            configuration.title
        }
    }
}

/// 不占右侧空间的展开样式:内容自己带箭头,系统不再留一条指示位。
private struct FlatDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { configuration.isExpanded.toggle() } }
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct WorkspaceOutputReferences: View {
    let text: String
    let files: [WorkspaceFile]
    let onOpenFile: (String) -> Void

    private var referencedFiles: [WorkspaceFile] {
        files.filter { text.localizedStandardContains($0.relativePath) }.prefix(6).map { $0 }
    }

    var body: some View {
        if !referencedFiles.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(referencedFiles) { file in
                    Button {
                        onOpenFile(file.relativePath)
                    } label: {
                        HStack(spacing: 8) {
                            FileTypeGlyph.icon(for: file.relativePath, size: 18)
                            Text("预览 \(file.relativePath)")
                                .font(.footnote)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("在当前 DSH 工作区中打开此文件的预览")
                }
            }
            .padding(.top, 4)
        }
    }
}

private func workspaceRelativePath(from url: URL) -> String? {
    let scheme = url.scheme?.lowercased()
    var path: String
    switch scheme {
    case nil, "file", "sandbox":
        guard url.host == nil || url.host?.isEmpty == true else { return nil }
        path = url.path.removingPercentEncoding ?? url.path
    case "dsh-resource":
        // DSH's own file address — `dsh-resource://file/session/<id>/<path>`
        // (workspace-relative, or absolute with the leading `/` dropped) and
        // `dsh-resource://file/absolute/<path>`. The web surface accepts
        // these; a native message that quotes one used to fall through to the
        // system as an unopenable URL, which read as "the file is missing".
        guard url.host?.lowercased() == "file" else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let scope = segments.first else { return nil }
        let tail: [String]
        switch scope {
        case "session" where segments.count >= 3: tail = Array(segments.dropFirst(2))
        case "absolute" where segments.count >= 2: tail = Array(segments.dropFirst())
        default: return nil
        }
        var joined = tail.joined(separator: "/")
        if joined == "dsh/workspace" { return nil }
        if joined.hasPrefix("dsh/workspace/") {
            joined = String(joined.dropFirst("dsh/workspace/".count))
        } else if joined.hasPrefix("dsh/") {
            return nil
        }
        path = joined
    default:
        return nil
    }
    if path.hasPrefix("/dsh/workspace/") {
        path = String(path.dropFirst("/dsh/workspace/".count))
    } else if path.hasPrefix("dsh/workspace/") {
        path = String(path.dropFirst("dsh/workspace/".count))
    } else if path == "/dsh/workspace" || path == "dsh/workspace" {
        return nil
    } else if path.hasPrefix("/") {
        return nil
    }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let components = path.split(separator: "/")
    guard !components.isEmpty, !components.contains("."), !components.contains("..") else { return nil }
    return components.joined(separator: "/").precomposedStringWithCanonicalMapping
}

struct RuntimeDetailsPage: View {
    @Bindable var model: ChatModel

    @State private var confirmingStop = false

    /// Label left, 15pt gray value right (HomeSpec list row).
    private func runtimeRow(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(HomeSpec.textPlaceholder)
                .monospacedDigit()
        } label: {
            Text(title)
        }
    }

    /// 状态词 + 已运行多久,两个都在第一行。
    private var statusValue: String {
        guard let startedAt = model.startedAt, model.isStarted else { return model.displayStatus }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let elapsed: String
        if seconds < 60 {
            elapsed = "不到 1 分钟"
        } else if seconds < 3600 {
            elapsed = "\(seconds / 60) 分钟"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            elapsed = minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
        }
        return "\(model.displayStatus) · 已运行\(elapsed)"
    }

    private var hasCounts: Bool {
        model.modelRequests > 0 || model.inputTokens > 0 || model.outputTokens > 0
    }

    var body: some View {
        List {
            Section {
                // 停完留在这一页:顶上写「已停止」,下面就是重新启动的按钮。
                runtimeRow("状态", model.isStarted ? statusValue : "已停止")
            }

            if hasCounts {
                Section("本次运行") {
                    runtimeRow("模型调用", "\(model.modelRequests)")
                    runtimeRow("输入 Token", model.inputTokens.formatted())
                    runtimeRow("输出 Token", model.outputTokens.formatted())
                }
            }

            Section("最近出错") {
                // 组标题已经说了「最近出错」,行里不再重复一个同名标签,只放那句话。
                Text(model.userFacingError ?? "最近没有出错")
                    .foregroundStyle(model.userFacingError == nil ? HomeSpec.textPlaceholder : ChatPage.danger)
            }

            Section {
                if model.isStarted {
                    Button("停止本地引擎", role: .destructive) { confirmingStop = true }
                } else {
                    Button("启动本地引擎") { Task { await model.start() } }
                        .buttonStyle(HomePrimaryButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } footer: {
                Text("停止后,正在跑的任务会停下来,不会再接着做。")
            }
        }
        .homeGroupedList()
        .navigationTitle("运行状态")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("停止本地引擎?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("取消", role: .cancel) {}
            Button("停止", role: .destructive) { Task { await model.stop() } }
        } message: {
            Text("正在跑的任务会停下来。会话和文件都还在。")
        }
    }
}

private struct CommandExecutionResultPage: View {
    let execution: NativeCommandExecution
    let onOpenFile: (String) -> Void
    @State private var model = ChatModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(execution.kind == "success" ? "命令已完成" : "命令执行失败",
                          systemImage: execution.kind == "success" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(execution.kind == "success" ? Color.primary : Color.red)
                    Text(execution.line)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 12))
                    if let text = execution.text, !text.isEmpty {
                        MarkdownContent(text: text, onOpenFile: onOpenFile)
                        WorkspaceOutputReferences(text: text, files: model.files, onOpenFile: onOpenFile)
                    } else {
                        Text("这次没有更多输出。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }
            .navigationTitle("命令结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.fontWeight(.semibold) }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: execution.text ?? execution.line,
                              subject: Text("命令结果"),
                              preview: SharePreview("/\(execution.name)")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享命令结果")
                }
            }
        }
    }
}

private struct NativeTrajectoryRow: View {
    let entry: NativeTrajectoryEntry
    let onOpenFile: (String) -> Void
    @State private var expanded = false

    private var payloadText: String {
        guard let data = try? entry.payload.encoded() else { return "无法格式化此事件的原始数据。" }
        return String(data: data, encoding: .utf8) ?? "无法读取此事件的原始数据。"
    }

    private var categoryTitle: String {
        switch entry.category {
        case .userMessage: "用户消息"
        case .assistantMessage: "助手消息"
        case .systemPrompt: "系统提示"
        case .steeringMessage: "补充说明"
        case .developerMessage: "开发者消息"
        case .toolCall: "工具调用"
        case .toolResult: "工具结果"
        case .requestBoundary: "模型请求"
        case .compaction: "上下文整理"
        case .command: "DSH 命令"
        case .sessionBoundary: "会话边界"
        case .otherBusiness: "会话事件"
        }
    }

    private var categoryIcon: String {
        switch entry.category {
        case .userMessage: "person"
        case .assistantMessage: "sparkles"
        case .systemPrompt: "doc.text"
        case .steeringMessage: "arrow.uturn.forward"
        case .developerMessage: "wrench.and.screwdriver"
        case .toolCall: "terminal"
        case .toolResult: "checkmark.circle"
        case .requestBoundary: "arrow.up.right.circle"
        case .compaction: "arrow.trianglehead.2.clockwise.rotate.90"
        case .command: "command"
        case .sessionBoundary: "rectangle.stack"
        case .otherBusiness: "circle.dashed"
        }
    }

    private var showsPreviewInCollapsedRow: Bool {
        switch entry.category {
        case .userMessage, .assistantMessage, .steeringMessage, .toolCall, .toolResult, .command:
            true
        default:
            false
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !entry.preview.isEmpty {
                    MarkdownContent(text: entry.preview, onOpenFile: onOpenFile)
                    WorkspaceOutputReferences(text: entry.preview, files: ChatModel.shared.files, onOpenFile: onOpenFile)
                }
                Text(payloadText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                    .contextMenu {
                        Button("复制事件数据", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = payloadText
                        }
                    }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: categoryIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(categoryTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("#\(entry.seq)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if showsPreviewInCollapsedRow && !entry.preview.isEmpty {
                        Text(entry.preview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 2)
                    }
                    // 只留时间:eventType 是宿主那边的英文名,不该上屏。
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// Debug-only sheet token so `PDSH_DEBUG_SHEET=provider` can present the model
/// provider page without UI automation.
struct DebugSheetToken: Identifiable {
    let value: String
    var id: String { value }
}

// 页头规矩(全站一个数):文字左缘 20,标题仍居中;右侧按钮的右缘跟着 20。
// iOS 26 给工具栏按钮套了一层玻璃胶囊,文字墨迹会比栏边多缩进 13,
// 去掉胶囊之后还剩 2 的差,只有 offset 能真的补上(padding 在这一层会被夹住)。
extension View {
    func leadingBarText() -> some View { self.buttonStyle(.plain).offset(x: -2) }
    func trailingBarText() -> some View { self.buttonStyle(.plain).offset(x: 2) }
}


/// 权限卡本体。真实对话和 `-uiPreview chat.permission` 用同一份画法,
/// 文案、颜色、按钮尺寸不会两处漂移。
struct PermissionCardView: View {
    let permission: ChatPermission
    var isBusy: Bool = false
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}

    var body: some View {
        let category = ToolWording.category(forToolName: permission.tool)
        let detail = ToolWording.detail(for: category, arguments: permission.arguments)
        VStack(alignment: .leading, spacing: 10) {
            Label("等待授权", systemImage: "hand.raised.fill")
                .font(.headline)
            // 标题是中文问句;工具名、宿主给的英文 reason 都不上屏。
            Text(category.permissionTitle)
                .font(.subheadline.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 15, design: category == .execute ? .monospaced : .default))
                    .foregroundStyle(NativeChatTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Button {
                onAllow()
            } label: {
                Text("允许一次")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(NativeChatTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)

            Button {
                onDeny()
            } label: {
                Text("拒绝")
                    .font(.system(size: 15))
                    .foregroundStyle(NativeChatTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeChatTheme.selector, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
