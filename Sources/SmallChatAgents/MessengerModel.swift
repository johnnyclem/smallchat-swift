import Foundation
import Observation

// MARK: - Messenger model
//
// The app's single source of truth for agents and chats. Lives in the
// library (not the app target) so everything but the views is testable.

@MainActor @Observable
public final class MessengerModel {

    // MARK: State

    /// Every known, non-hidden session: live first, then most recent.
    public private(set) var agents: [AgentSession] = []
    public private(set) var conversations: [Conversation] = []
    public private(set) var ledger = TruthLedgerSnapshot()
    public var settings: MessengerSettings {
        didSet {
            applyAgentFilter()
            persist()
        }
    }
    public var selectedConversationId: String?
    /// Conversation id → agent ids we're waiting to hear back from.
    public private(set) var awaiting: [String: Set<String>] = [:]
    /// Agent id → what it's doing right now (tool name), while awaited.
    public private(set) var agentActivity: [String: String] = [:]
    public private(set) var isRefreshing = false
    /// Last problem worth telling the user about.
    public var lastError: String?

    // MARK: Dependencies

    private var records: [String: AgentRecord]
    private var stenographerSessions: [String: String]
    private let store: MessengerStore
    private let scanner: ClaudeSessionScanner?
    public private(set) var transport: any AgentTransport
    private var inboundTask: Task<Void, Never>?
    /// Agent id → the conversation it was last prompted from (where an
    /// out-of-band reply belongs).
    private var replyRoute: [String: String] = [:]
    /// Every agent including archived and filtered-out ones.
    private var allAgents: [AgentSession] = []
    /// Result of the last disk scan, reused when rebuilding after local changes.
    private var lastDiscovered: [DiscoveredSession] = []

    public init(store: MessengerStore, transport: any AgentTransport, scanner: ClaudeSessionScanner?) {
        let snapshot = store.load()
        self.store = store
        self.scanner = scanner
        self.transport = transport
        self.records = snapshot.agents
        self.conversations = snapshot.conversations
        self.stenographerSessions = snapshot.stenographerSessions
        self.settings = snapshot.settings
        rebuildAgents()
        listenForInbound()
        reloadLedger()
    }

    /// Swap the transport (e.g. after the `claude` path changes in Settings).
    public func setTransport(_ transport: any AgentTransport) {
        self.transport = transport
        listenForInbound()
    }

    // MARK: Lookup

    public func agent(_ id: String) -> AgentSession? {
        allAgents.first { $0.id == id }
    }

    public func agent(handle: String) -> AgentSession? {
        let h = Handles.normalize(handle)
        return allAgents.first { $0.handle == h }
    }

    public func conversation(_ id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    public var archivedAgents: [AgentSession] {
        allAgents.filter(\.archived).sorted { $0.lastActivity > $1.lastActivity }
    }

    public var groups: [Conversation] {
        conversations.filter { $0.kind == .group }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func directConversation(with agentId: String) -> Conversation? {
        conversations.first { $0.kind == .direct && $0.memberIds == [agentId] }
    }

    /// Display name for a message author.
    public func displayName(_ author: MessageAuthor) -> String {
        switch author {
        case .user: return "You"
        case .agent(let id): return agent(id).map { "@\($0.handle)" } ?? "@unknown"
        case .stenographer: return "@\(Handles.stenographer)"
        case .system: return "smallchat"
        }
    }

    /// Handles offered by @-autocomplete in a conversation: members first.
    public func mentionSuggestions(for query: String, in conversationId: String?) -> [String] {
        let q = query.lowercased()
        let members = Set(conversationId.flatMap(conversation)?.memberIds ?? [])
        let candidates = agents
            .sorted { (members.contains($0.id) ? 0 : 1, $0.handle) < (members.contains($1.id) ? 0 : 1, $1.handle) }
            .map(\.handle)
        let specials = [Handles.stenographer, "all"]
        return (candidates + specials).filter { q.isEmpty || $0.hasPrefix(q) }.prefix(8).map { $0 }
    }

    // MARK: Discovery

    /// Rescan Claude Code's session files (off the main actor).
    public func refresh() async {
        guard let scanner else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let discovered = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
        rebuildAgents(discovered: discovered)
    }

    /// Cheap poll: re-read only the live-session registry and update
    /// busy/idle/stopped on the last full scan. Safe to run every few seconds.
    public func refreshLive() async {
        guard let scanner else { return }
        let live = await Task.detached(priority: .utility) { scanner.liveRecords() }.value
        let byId = Dictionary(live.compactMap { r in r.sessionId.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        var discovered = lastDiscovered
        let known = Set(discovered.map(\.sessionId))
        for index in discovered.indices {
            discovered[index].live = byId[discovered[index].sessionId]
        }
        // A session started since the last full scan: show it now.
        for record in live {
            guard let id = record.sessionId, !known.contains(id) else { continue }
            discovered.append(DiscoveredSession(
                sessionId: id, cwd: record.cwd ?? "", gitBranch: nil, title: nil,
                lastActivity: record.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                transcriptPath: nil, live: record
            ))
        }
        if discovered != lastDiscovered { rebuildAgents(discovered: discovered) }
    }

    func rebuildAgents(discovered: [DiscoveredSession]? = nil) {
        let discovered = discovered ?? lastDiscovered
        lastDiscovered = discovered
        var taken = Set(records.values.map(\.handle))
        var sessions: [AgentSession] = []
        var seen = Set<String>()
        var recordsChanged = false

        for found in discovered {
            seen.insert(found.sessionId)
            var record = records[found.sessionId]
            if record == nil {
                let handle = Handles.suggest(
                    sessionId: found.sessionId,
                    cwd: found.cwd,
                    claudeName: found.live?.name,
                    claudeNameIsUserChosen: found.live?.nameIsUserChosen ?? false,
                    taken: taken
                )
                taken.insert(handle)
                record = AgentRecord(handle: handle, cwd: found.cwd)
                records[found.sessionId] = record
                recordsChanged = true
            } else if record?.cwd != found.cwd, !found.cwd.isEmpty {
                records[found.sessionId]?.cwd = found.cwd
                record?.cwd = found.cwd
                recordsChanged = true
            }
            guard let record else { continue }
            sessions.append(AgentSession(
                id: found.sessionId,
                handle: record.handle,
                claudeName: found.live?.name,
                cwd: found.cwd.isEmpty ? (record.cwd ?? "") : found.cwd,
                gitBranch: found.gitBranch,
                title: found.title,
                lastActivity: found.lastActivity,
                activity: found.live?.activity ?? .stopped,
                kind: found.live?.agentKind ?? .unknown,
                archived: record.archived,
                transcriptPath: found.transcriptPath
            ))
        }

        // Sessions we know (created here, or seen before) that the scan missed.
        for (id, record) in records where !seen.contains(id) {
            let previous = allAgents.first { $0.id == id }
            sessions.append(AgentSession(
                id: id,
                handle: record.handle,
                claudeName: previous?.claudeName,
                cwd: record.cwd ?? previous?.cwd ?? "",
                gitBranch: previous?.gitBranch,
                title: previous?.title,
                lastActivity: previous?.lastActivity ?? record.createdAt,
                activity: .stopped,
                kind: previous?.kind ?? .unknown,
                archived: record.archived,
                transcriptPath: previous?.transcriptPath
            ))
        }

        allAgents = sessions
        applyAgentFilter()
        if recordsChanged { persist() }
    }

    private func applyAgentFilter(now: Date = Date()) {
        let cutoff = settings.recentDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let inConversation = Set(conversations.flatMap(\.memberIds))
        agents = allAgents
            .filter { !$0.archived }
            .filter { agent in
                guard let cutoff else { return true }
                return agent.isLive || agent.lastActivity >= cutoff || inConversation.contains(agent.id)
            }
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive { return lhs.isLive }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    /// Refresh Claude Code's own names for live sessions (for addressing).
    public func refreshLiveNames() async {
        let live = await transport.listLiveNames()
        guard !live.isEmpty else { return }
        for index in allAgents.indices where allAgents[index].isLive {
            let agent = allAgents[index]
            let matches = live.filter { $0.cwd == agent.cwd }
            if matches.count == 1 { allAgents[index].claudeName = matches[0].name }
        }
        applyAgentFilter()
    }

    // MARK: Naming & archiving

    /// Rename an agent's handle. Throws `HandleError` with a user-facing message.
    public func rename(agentId: String, to newHandle: String) throws {
        guard records[agentId] != nil else { return }
        let taken = Set(records.filter { $0.key != agentId }.map(\.value.handle))
        let handle = try Handles.validate(newHandle, taken: taken)
        records[agentId]?.handle = handle
        for index in allAgents.indices where allAgents[index].id == agentId {
            allAgents[index].handle = handle
        }
        for index in conversations.indices where conversations[index].kind == .direct && conversations[index].memberIds == [agentId] {
            conversations[index].title = handle
        }
        applyAgentFilter()
        persist()
    }

    public func setArchived(agentId: String, _ archived: Bool) {
        guard records[agentId] != nil else { return }
        records[agentId]?.archived = archived
        for index in allAgents.indices where allAgents[index].id == agentId {
            allAgents[index].archived = archived
        }
        applyAgentFilter()
        persist()
    }

    // MARK: Conversations

    /// Open (or create) the direct chat with an agent and select it.
    @discardableResult
    public func openDirect(agentId: String) -> String? {
        guard agent(agentId) != nil else { return nil }
        let id = ensureDirectConversation(agentId: agentId)
        selectedConversationId = id
        return id
    }

    /// The direct chat with an agent, created if needed, without selecting it.
    private func ensureDirectConversation(agentId: String) -> String {
        if let existing = directConversation(with: agentId) { return existing.id }
        let conversation = Conversation(kind: .direct, title: agent(agentId)?.handle ?? agentId, memberIds: [agentId])
        conversations.append(conversation)
        persist()
        return conversation.id
    }

    @discardableResult
    public func createGroup(title: String, memberIds: [String]) -> String? {
        let members = memberIds.filter { agent($0) != nil }
        guard !members.isEmpty else {
            lastError = "A group needs at least one agent."
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? members.compactMap { agent($0)?.handle }.joined(separator: ", ") : trimmed
        var conversation = Conversation(kind: .group, title: name, memberIds: members)
        conversation.messages.append(ChatMessage(
            author: .system,
            text: "Group created with " + members.compactMap { agent($0).map { "@\($0.handle)" } }.joined(separator: ", ")
                + ". Messages you send go to every agent unless you @mention specific ones. "
                + "Agent replies come to you privately — share one to interrupt the others with it."
        ))
        conversations.append(conversation)
        selectedConversationId = conversation.id
        persist()
        return conversation.id
    }

    public func setMembers(_ memberIds: [String], of conversationId: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[index].kind == .group, !memberIds.isEmpty else { return }
        conversations[index].memberIds = memberIds
        persist()
    }

    public func renameConversation(_ conversationId: String, to title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[index].kind == .group else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversations[index].title = trimmed
        persist()
    }

    public func deleteConversation(_ conversationId: String) {
        conversations.removeAll { $0.id == conversationId }
        awaiting[conversationId] = nil
        stenographerSessions[conversationId] = nil
        if selectedConversationId == conversationId { selectedConversationId = nil }
        persist()
    }

    // MARK: Sending

    /// Send what the user typed into a conversation.
    public func send(_ rawText: String, in conversationId: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = conversation(conversationId) else { return }

        let plan = ChatRouter.planUserMessage(text, in: conversation, agents: allAgents.filter { !$0.archived })
        append(ChatMessage(
            author: .user, text: text,
            recipients: plan.deliveries.map(\.recipientId),
            delivery: plan.deliveries.isEmpty ? .delivered : .pending
        ), to: conversationId)

        if !plan.unknownHandles.isEmpty {
            append(ChatMessage(
                author: .system,
                text: "No agent named " + plan.unknownHandles.map { "@\($0)" }.joined(separator: ", ") + " — nothing was sent to them."
            ), to: conversationId)
        }
        if !plan.outsideRecipients.isEmpty {
            let names = plan.outsideRecipients.compactMap { agent($0).map { "@\($0.handle)" } }
            append(ChatMessage(author: .system, text: "Also sent to " + names.joined(separator: ", ") + " (not in this chat)."), to: conversationId)
        }

        for delivery in plan.deliveries {
            deliver(delivery, from: conversationId)
        }
        if plan.asksStenographer {
            askStenographer(text, in: conversationId)
        }
    }

    /// Share a private agent reply with the rest of the group — delivered
    /// to each other member as an inter-agent interrupt.
    public func share(messageId: String, in conversationId: String) {
        guard let conversation = conversation(conversationId),
              let message = conversation.messages.first(where: { $0.id == messageId }),
              message.awaitingShareDecision else { return }
        let deliveries = ChatRouter.planShare(message, in: conversation, agents: allAgents)
        updateMessage(messageId, in: conversationId) {
            $0.visibility = .group
            $0.shareDecided = true
            $0.recipients = deliveries.map(\.recipientId)
        }
        for delivery in deliveries {
            deliver(delivery, from: conversationId)
        }
    }

    public func keepPrivate(messageId: String, in conversationId: String) {
        updateMessage(messageId, in: conversationId) { $0.shareDecided = true }
    }

    /// Create a new Claude Code session and open a chat with it.
    public func startAgent(handle rawHandle: String, cwd: String, prompt: String) throws {
        let taken = Set(records.values.map(\.handle))
        let handle = try Handles.validate(rawHandle, taken: taken)
        let firstPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstPrompt.isEmpty else { return }

        // Placeholder conversation until the session id arrives.
        var conversation = Conversation(kind: .direct, title: handle, memberIds: [])
        conversation.messages.append(ChatMessage(author: .user, text: firstPrompt, delivery: .pending))
        conversations.append(conversation)
        selectedConversationId = conversation.id
        let conversationId = conversation.id
        let stream = transport.startSession(name: handle, cwd: cwd, prompt: firstPrompt)

        Task { [weak self] in
            var sessionId: String?
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .sessionStarted(let id):
                        sessionId = id
                        self.adoptNewSession(id: id, handle: handle, cwd: cwd, conversationId: conversationId)
                    case .reply(let text):
                        if let sessionId { self.receiveReply(from: sessionId, text: text, in: conversationId) }
                    case .activity(let name):
                        if let sessionId { self.agentActivity[sessionId] = name }
                    case .delivered:
                        self.markUserMessages(in: conversationId, as: .delivered)
                    }
                }
            } catch {
                self?.fail(error, conversationId: conversationId, agentId: sessionId)
            }
            if let sessionId { self?.stopAwaiting(sessionId, in: conversationId) }
        }
    }

    // MARK: Delivery internals

    private func deliver(_ delivery: Delivery, from conversationId: String) {
        guard let agent = agent(delivery.recipientId) else { return }
        replyRoute[agent.id] = conversationId
        // A prompt owes the user an answer; a shared interrupt doesn't (if the
        // agent does respond, `replyRoute` still brings it here).
        if delivery.style == .prompt {
            awaiting[conversationId, default: []].insert(agent.id)
        }
        let stream = transport.send(delivery.body, to: agent, style: delivery.style)
        Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .delivered:
                        self.markUserMessages(in: conversationId, as: .delivered)
                    case .activity(let name):
                        self.agentActivity[agent.id] = name
                    case .reply(let text):
                        self.receiveReply(from: agent.id, text: text, in: conversationId)
                    case .sessionStarted:
                        break
                    }
                }
                // A live agent answers later via the switchboard; a resumed one is done.
                if delivery.style != .prompt || !agent.isLive || agent.claudeName == nil {
                    self?.stopAwaiting(agent.id, in: conversationId)
                }
            } catch {
                self?.fail(error, conversationId: conversationId, agentId: agent.id)
            }
        }
    }

    private func listenForInbound() {
        inboundTask?.cancel()
        let inbound = transport.inbound
        inboundTask = Task { [weak self] in
            for await reply in inbound {
                self?.handleInbound(reply)
            }
        }
    }

    func handleInbound(_ reply: InboundReply) {
        let name = reply.senderName.lowercased()
        guard let agent = allAgents.first(where: { $0.claudeName?.lowercased() == name })
            ?? allAgents.first(where: { $0.handle == Handles.normalize(name) }) else {
            // Someone we don't track — surface it rather than drop it.
            if let id = selectedConversationId {
                append(ChatMessage(author: .system, text: "Message from @\(reply.senderName) (unknown session):\n\(reply.text)"), to: id)
            }
            return
        }
        // Never yank the user's selection over to an unsolicited reply.
        let conversationId = replyRoute[agent.id] ?? ensureDirectConversation(agentId: agent.id)
        receiveReply(from: agent.id, text: reply.text, in: conversationId)
    }

    func receiveReply(from agentId: String, text: String, in conversationId: String) {
        guard let conversation = conversation(conversationId) else { return }
        let isGroup = conversation.kind == .group
        append(ChatMessage(
            author: .agent(agentId),
            text: text,
            visibility: isGroup ? .privateToUser : .group,
            shareDecided: !isGroup
        ), to: conversationId)
        stopAwaiting(agentId, in: conversationId)
    }

    private func stopAwaiting(_ agentId: String, in conversationId: String) {
        awaiting[conversationId]?.remove(agentId)
        if awaiting[conversationId]?.isEmpty == true { awaiting[conversationId] = nil }
        if !awaiting.values.contains(where: { $0.contains(agentId) }) { agentActivity[agentId] = nil }
    }

    private func fail(_ error: Error, conversationId: String, agentId: String?) {
        let who = agentId.flatMap { agent($0) }.map { "@\($0.handle)" } ?? "the agent"
        let reason = String(describing: error)
        append(ChatMessage(author: .system, text: "Couldn't reach \(who): \(reason)", delivery: .failed(reason)), to: conversationId)
        if let agentId { stopAwaiting(agentId, in: conversationId) }
        lastError = reason
    }

    private func adoptNewSession(id: String, handle: String, cwd: String, conversationId: String) {
        records[id] = AgentRecord(handle: handle, cwd: cwd)
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].memberIds = [id]
            for m in conversations[index].messages.indices where conversations[index].messages[m].author == .user {
                conversations[index].messages[m].recipients = [id]
            }
        }
        rebuildAgents()
        awaiting[conversationId, default: []].insert(id)
        replyRoute[id] = conversationId
        persist()
        Task { await self.refresh() }
    }

    private func markUserMessages(in conversationId: String, as state: DeliveryState) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        for m in conversations[index].messages.indices.reversed() {
            let message = conversations[index].messages[m]
            if message.author == .user, message.delivery == .pending {
                conversations[index].messages[m].delivery = state
            }
        }
        persist()
    }

    // MARK: Stenographer

    public func reloadLedger() {
        ledger = TruthLedgerSnapshot.load(paths: settings.wikiPaths)
    }

    private func askStenographer(_ question: String, in conversationId: String) {
        guard let conversation = conversation(conversationId) else { return }
        let prompt = Stenographer.prompt(question: question, recent: conversation.messages) { [weak self] in
            self?.displayName($0) ?? "?"
        }
        let cwd = conversation.memberIds.first.flatMap { agent($0) }?.cwd
        let stream = transport.askStenographer(
            prompt, brief: Stenographer.brief(ledger: ledger),
            resumeSessionId: stenographerSessions[conversationId], cwd: cwd
        )
        awaiting[conversationId, default: []].insert(Handles.stenographer)
        Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .sessionStarted(let id):
                        self.stenographerSessions[conversationId] = id
                    case .reply(let text):
                        self.append(ChatMessage(author: .stenographer, text: text, visibility: .privateToUser, shareDecided: true), to: conversationId, observe: false)
                    default:
                        break
                    }
                }
            } catch {
                self?.append(ChatMessage(author: .system, text: "The stenographer couldn't answer: \(error)"), to: conversationId, observe: false)
            }
            self?.stopAwaiting(Handles.stenographer, in: conversationId)
        }
    }

    // MARK: Mutation helpers

    private func append(_ message: ChatMessage, to conversationId: String, observe: Bool = true) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = message.timestamp

        let watchable: Bool
        switch message.author {
        case .user, .agent: watchable = true
        case .stenographer, .system: watchable = false
        }
        if observe, watchable, settings.stenographerWatching {
            for note in Stenographer.observe(message.text, ledger: ledger) {
                conversations[index].messages.append(ChatMessage(
                    author: .stenographer,
                    text: note.text,
                    visibility: .privateToUser,
                    shareDecided: true,
                    citedEntryId: note.entryId
                ))
            }
        }
        persist()
    }

    private func updateMessage(_ messageId: String, in conversationId: String, _ change: (inout ChatMessage) -> Void) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationId }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageId }) else { return }
        change(&conversations[c].messages[m])
        persist()
    }

    private func persist() {
        let snapshot = MessengerSnapshot(
            agents: records,
            conversations: conversations,
            stenographerSessions: stenographerSessions,
            settings: settings
        )
        do {
            try store.save(snapshot)
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
