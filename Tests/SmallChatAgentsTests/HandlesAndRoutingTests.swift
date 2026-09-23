import Foundation
import Testing
@testable import SmallChatAgents

@Suite("Handles")
struct HandleTests {
    @Test("validate normalizes and rejects bad names")
    func validate() throws {
        #expect(try Handles.validate("@Instrument-62", taken: []) == "instrument-62")
        #expect(throws: HandleError.empty) { try Handles.validate("  ", taken: []) }
        #expect(throws: HandleError.invalidCharacters) { try Handles.validate("has space", taken: []) }
        #expect(throws: HandleError.invalidCharacters) { try Handles.validate("-leading", taken: []) }
        #expect(throws: HandleError.reserved("stenographer")) { try Handles.validate("Stenographer", taken: []) }
        #expect(throws: HandleError.reserved("all")) { try Handles.validate("all", taken: []) }
        #expect(throws: HandleError.taken("bob")) { try Handles.validate("BOB", taken: ["bob"]) }
        #expect(throws: HandleError.tooLong(max: 32)) { try Handles.validate(String(repeating: "a", count: 33), taken: []) }
    }

    @Test("slugify collapses punctuation")
    func slugify() {
        #expect(Handles.slugify("My Project (v2)") == "my-project-v2")
        #expect(Handles.slugify("  --llm_wiki--  ") == "llm_wiki")
    }

    @Test("suggest uses project + short id, lengthening on collision")
    func suggest() {
        let first = Handles.suggest(sessionId: "62ab-ffff", cwd: "/Users/j/Repos/instrument",
                                    claudeName: "user-0d", claudeNameIsUserChosen: false, taken: [])
        #expect(first == "instrument-62")
        let second = Handles.suggest(sessionId: "62ac-0000", cwd: "/Users/j/Repos/instrument",
                                     claudeName: nil, claudeNameIsUserChosen: false, taken: ["instrument-62"])
        #expect(second == "instrument-62a")
    }

    @Test("a user-chosen Claude Code name wins")
    func suggestUserChosen() {
        let handle = Handles.suggest(sessionId: "abcd", cwd: "/x/instrument",
                                     claudeName: "Release Notes", claudeNameIsUserChosen: true, taken: [])
        #expect(handle == "release-notes")
    }
}

@Suite("Mentions")
struct MentionTests {
    @Test("finds plain, quoted, and punctuated mentions")
    func parse() {
        let parse = MentionParser.parse("@alpha can you ask @\"Release Notes\" and @beta-, cc @all")
        #expect(parse.handles == ["alpha", "release notes", "beta", "all"])
        #expect(parse.mentionsBroadcast)
        #expect(!parse.mentionsStenographer)
    }

    @Test("emails are not mentions")
    func emails() {
        #expect(MentionParser.parse("mail me@example.com").mentions.isEmpty)
    }

    @Test("ranges cover the token in UTF-16")
    func ranges() {
        let text = "héllo @bob!"
        let mention = MentionParser.parse(text).mentions[0]
        #expect((text as NSString).substring(with: mention.range) == "@bob")
    }

    @Test("autocomplete query and completion")
    func autocomplete() {
        #expect(MentionParser.activeQuery(in: "hey @ins") == "ins")
        #expect(MentionParser.activeQuery(in: "hey @") == "")
        #expect(MentionParser.activeQuery(in: "hey @ins now") == nil)
        #expect(MentionParser.activeQuery(in: "me@ex") == nil)
        #expect(MentionParser.complete("hey @ins", with: "instrument-62") == "hey @instrument-62 ")
    }
}

@Suite("Router")
struct RouterTests {
    let a = AgentSession(id: "A", handle: "alpha", cwd: "/r/a", lastActivity: Date())
    let b = AgentSession(id: "B", handle: "beta", cwd: "/r/b", lastActivity: Date())
    let c = AgentSession(id: "C", handle: "gamma", cwd: "/r/c", lastActivity: Date())
    var agents: [AgentSession] { [a, b, c] }
    var group: Conversation { Conversation(kind: .group, title: "ship it", memberIds: ["A", "B"]) }

    @Test("no mentions fans out to every member")
    func fanOut() {
        let plan = ChatRouter.planUserMessage("status?", in: group, agents: agents)
        #expect(plan.deliveries.map(\.recipientId) == ["A", "B"])
        #expect(plan.deliveries[0].body.contains("group “ship it”"))
        #expect(plan.deliveries[0].body.contains("you (@alpha)"))
        #expect(plan.deliveries[0].body.hasSuffix("status?"))
    }

    @Test("mentions narrow delivery and can reach outside the group")
    func mentions() {
        let plan = ChatRouter.planUserMessage("@beta and @gamma look", in: group, agents: agents)
        #expect(plan.deliveries.map(\.recipientId) == ["B", "C"])
        #expect(plan.outsideRecipients == ["C"])
    }

    @Test("@all plus an outsider")
    func all() {
        let plan = ChatRouter.planUserMessage("@all and @gamma", in: group, agents: agents)
        #expect(plan.deliveries.map(\.recipientId) == ["A", "B", "C"])
    }

    @Test("stenographer-only and unknown mentions never broadcast")
    func noBroadcastFallback() {
        let steno = ChatRouter.planUserMessage("@stenographer what's dead?", in: group, agents: agents)
        #expect(steno.deliveries.isEmpty)
        #expect(steno.asksStenographer)
        let unknown = ChatRouter.planUserMessage("@nobody hi", in: group, agents: agents)
        #expect(unknown.deliveries.isEmpty)
        #expect(unknown.unknownHandles == ["nobody"])
    }

    @Test("sharing interrupts every other member")
    func share() {
        let reply = ChatMessage(author: .agent("A"), text: "found it", visibility: .privateToUser)
        var three = group
        three.memberIds = ["A", "B", "C"]
        let deliveries = ChatRouter.planShare(reply, in: three, agents: agents)
        #expect(deliveries.map(\.recipientId) == ["B", "C"])
        #expect(deliveries.allSatisfy { $0.style == .interrupt })
        #expect(deliveries[0].body.contains("@alpha shared this with the group"))
    }
}
