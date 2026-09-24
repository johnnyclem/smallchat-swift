import Foundation
import Observation
import SmallChatTruth

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
    /// Agent id → live tool activity read from its transcript (live sessions only).
    public private(set) var liveActivity: [String: ActivitySnapshot] = [:]
    public private(set) var isRefreshing = false
    /// Objections received on the channel, newest first.
    public private(set) var objections: [ReceivedObjection] = []
    /// Tombstones agents drafted for the user to notarize, newest first.
    public private(set) var pendingProposals: [PendingProposal] = []
    public private(set) var objectionChannelStatus: ObjectionChannelStatus = .off
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
    private var bridge: ChannelBridgeServer?
    private var seenObjectionIds = Set<String>()
    /// Transcript size per live agent when its activity was last read.
    private var activitySizes: [String: UInt64] = [:]
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
        if settings.objectionChannelSecret.isEmpty {
            settings.objectionChannelSecret = ChannelBridgeProtocol.generateSecret()
            persist()
        }
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
        await refreshActivity()
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
                transcriptPath: scanner.transcriptPath(sessionId: id, cwd: record.cwd ?? ""), live: record
            ))
        }
        if discovered != lastDiscovered { rebuildAgents(discovered: discovered) }
        await refreshActivity()
    }

    /// Re-read the transcript tail of every live session whose file changed.
    func refreshActivity() async {
        let targets = allAgents.compactMap { agent -> (String, String)? in
            guard agent.isLive, let path = agent.transcriptPath else { return nil }
            return (agent.id, path)
        }
        let previousSizes = activitySizes
        let results = await Task.detached(priority: .utility) { () -> [(String, UInt64, ActivitySnapshot?)] in
            targets.map { id, path in
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
                // Unchanged file → keep the snapshot we have.
                if previousSizes[id] == size { return (id, size, nil) }
                return (id, size, TranscriptActivity.read(transcriptAt: path))
            }
        }.value

        var next: [String: ActivitySnapshot] = [:]
        var sizes: [String: UInt64] = [:]
        for (id, size, snapshot) in results {
            sizes[id] = size
            if let kept = snapshot ?? liveActivity[id], !kept.isEmpty { next[id] = kept }
        }
        activitySizes = sizes
        if next != liveActivity { liveActivity = next }
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

    // MARK: Objection channel

    /// Start (or restart) the loopback bridge stenographer posts objections
    /// to, per the current settings.
    public func startObjectionChannel() async {
        await stopObjectionChannel()
        guard settings.objectionChannelEnabled else { return }
        let server = ChannelBridgeServer(
            port: settings.objectionChannelPort,
            secret: settings.objectionChannelSecret
        ) { [weak self] event in
            Task { @MainActor in self?.handleChannelEvent(event) }
        }
        do {
            let port = try await server.start()
            bridge = server
            objectionChannelStatus = .listening(port: port)
        } catch {
            await server.stop()
            objectionChannelStatus = .failed(String(describing: error))
        }
    }

    public func stopObjectionChannel() async {
        if let bridge { await bridge.stop() }
        bridge = nil
        objectionChannelStatus = .off
    }

    /// The `--objection-channel` URL to give stenographer.
    public var objectionChannelURL: String {
        "http://127.0.0.1:\(objectionChannelStatus.port ?? settings.objectionChannelPort)"
    }

    /// Route a bridge event to the agents it names (`meta.session_ids`).
    /// Objections land in each agent's chats (direct and group) and, when
    /// enabled, are relayed into the live session as an interrupt.
    func handleChannelEvent(_ event: ChannelInboundEvent) {
        if event.isProposal {
            receiveProposal(event)
            return
        }
        if event.isObjection, !event.objectionIds.isEmpty,
           event.objectionIds.allSatisfy(seenObjectionIds.contains) {
            return  // stenographer retried something we already have
        }
        seenObjectionIds.formUnion(event.objectionIds)

        let targets = event.sessionIds.compactMap { agent($0) }
        var relayed: [String] = []

        for target in targets {
            var conversationIds = [ensureDirectConversation(agentId: target.id)]
            conversationIds += conversations
                .filter { $0.kind == .group && $0.memberIds.contains(target.id) }
                .map(\.id)

            let message: ChatMessage
            if event.isObjection {
                message = ChatMessage(
                    author: .stenographer,
                    text: event.content,
                    visibility: .privateToUser,
                    shareDecided: true,
                    citedEntryId: event.tbIds.isEmpty ? nil : event.tbIds.joined(separator: ", ")
                )
            } else {
                let from = event.sender.map { "\($0) via \(event.channel)" } ?? event.channel
                message = ChatMessage(author: .system, text: "[\(from)] \(event.content)")
            }
            for id in conversationIds { append(message, to: id, observe: false) }

            guard event.isObjection, settings.relayObjections else { continue }
            if target.isLive {
                relay(event, to: target, noteIn: conversationIds[0])
                relayed.append(target.id)
            } else {
                append(ChatMessage(author: .system, text: "Objection not relayed: @\(target.handle) isn't running."), to: conversationIds[0], observe: false)
            }
        }

        if event.isObjection {
            objections.insert(ReceivedObjection(
                objectionIds: event.objectionIds,
                tbIds: event.tbIds,
                sessionIds: event.sessionIds,
                content: event.content,
                routedTo: targets.map(\.id),
                relayedTo: relayed
            ), at: 0)
            if objections.count > 100 { objections.removeLast(objections.count - 100) }
        }
    }

    // MARK: Notarization (agent-drafted tombstones)

    /// Stenographer's REST base, where drafts are listed and notarized.
    public var stenographerRestBase: URL {
        URL(string: "http://127.0.0.1:\(settings.stenographerRestPort)")!
    }

    /// An agent drafted a tombstone: queue it for the user and say so in the
    /// drafting agent's chat. The draft never reaches the agent as truth.
    private func receiveProposal(_ event: ChannelInboundEvent) {
        guard let id = event.proposalId, !pendingProposals.contains(where: { $0.id == id }) else { return }
        pendingProposals.insert(PendingProposal(
            id: id,
            draftedBy: event.draftedBy ?? event.sender ?? "an agent",
            sessionIds: event.sessionIds,
            content: event.content,
            notarizeURL: event.notarizeURL ?? NotaryClient.notarizeURL(restBase: stenographerRestBase, proposalId: id)
        ), at: 0)
        for target in event.sessionIds.compactMap({ agent($0) }) {
            append(ChatMessage(
                author: .stenographer,
                text: event.content + "\nApprove or decline it in Stenographer.",
                visibility: .privateToUser,
                shareDecided: true
            ), to: ensureDirectConversation(agentId: target.id), observe: false)
        }
    }

    /// Picks up drafts raised while the messenger wasn't listening.
    public func refreshProposals() async {
        do {
            let open = try await NotaryClient.openDrafts(restBase: stenographerRestBase)
            let known = Set(pendingProposals.map(\.id))
            pendingProposals.insert(contentsOf: open.filter { !known.contains($0.id) }, at: 0)
        } catch {
            // Stenographer's REST API isn't up (it's opt-in); pushes still arrive.
        }
    }

    /// Notarize (sign as the user) or decline a draft.
    public func decide(proposalId: String, _ decision: NotaryDecision) async {
        guard let proposal = pendingProposals.first(where: { $0.id == proposalId }), proposal.state.isOpen else { return }
        guard let url = proposal.notarizeURL else {
            setProposalState(proposalId, .failed("Stenographer didn't say where to notarize this. Is its REST API on?"))
            return
        }
        guard !settings.objectionChannelSecret.isEmpty else {
            setProposalState(proposalId, .failed("No notary secret is set."))
            return
        }
        if case .approve(let notary) = decision, notary.trimmingCharacters(in: .whitespaces).isEmpty {
            setProposalState(proposalId, .failed("Set who you sign as in Settings first."))
            return
        }
        setProposalState(proposalId, .working)
        do {
            let request = try NotaryClient.request(for: decision, notarizeURL: url, secret: settings.objectionChannelSecret)
            let entryId = try await NotaryClient.send(request)
            switch decision {
            case .approve: setProposalState(proposalId, .notarized(entryId: entryId))
            case .decline: setProposalState(proposalId, .declined)
            }
        } catch {
            setProposalState(proposalId, .failed(String(describing: error)))
        }
    }

    private func setProposalState(_ id: String, _ state: PendingProposal.State) {
        guard let index = pendingProposals.firstIndex(where: { $0.id == id }) else { return }
        pendingProposals[index].state = state
    }

    private func relay(_ event: ChannelInboundEvent, to agent: AgentSession, noteIn conversationId: String) {
        let body = "[smallchat · objection from the stenographer — relayed as it was raised]\n" + event.content
        let stream = transport.send(body, to: agent, style: .interrupt)
        Task { [weak self] in
            do {
                for try await _ in stream {}
            } catch {
                self?.append(ChatMessage(author: .system, text: "Couldn't relay the objection to @\(agent.handle): \(error)"), to: conversationId, observe: false)
            }
        }
    }

    // MARK: Authoring tombstones

    /// The wiki file new tombstones go to: the configured one, else the first
    /// wiki path (a directory gets `smallchat-tombstones.jsonl` inside it).
    public var tombstoneTarget: String? {
        let raw = settings.tombstoneFile ?? settings.wikiPaths.first
        guard let raw, !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return (path as NSString).appendingPathComponent("smallchat-tombstones.jsonl")
        }
        return path
    }

    /// Sign a tombstone and append it to the wiki. The stenographer starts
    /// objecting to its literals immediately; stenographer proper picks it
    /// up on its next `import_wiki_entries`.
    @discardableResult
    public func assertTombstone(_ draft: TombstoneDraft) throws -> TruthTbEntry {
        guard let target = tombstoneTarget else {
            throw TruthError.malformedLine(line: 0, reason: "Add a wiki file on the Stenographer page first — tombstones are written there.")
        }
        let entry = try draft.sign()
        try TruthWiki.append([.tb(entry)], toFileAt: target)
        // Make sure the ledger reads the file it was just written to.
        let covered = settings.wikiPaths.contains { path in
            let expanded = (path as NSString).expandingTildeInPath
            return expanded == target || target.hasPrefix(expanded.hasSuffix("/") ? expanded : expanded + "/")
        }
        if !covered { settings.wikiPaths.append(target) }
        if settings.signerIdentity.isEmpty { settings.signerIdentity = draft.signer.trimmingCharacters(in: .whitespaces) }
        reloadLedger()
        return entry
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
