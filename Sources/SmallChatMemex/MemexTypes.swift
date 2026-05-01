import Foundation
import SmallChatCore

// MARK: - SmallChatMemex types
//
// Mirrors the type vocabulary in TS PR #60. Memex is a knowledge-base
// compiler -- "sources are to Memex what tool manifests are to the
// ToolCompiler". A KnowledgeSource is parsed into ExtractedClaims that
// reference ExtractedEntities; claims and entities link to WikiPages;
// the whole thing rolls up into a KnowledgeBase.

// MARK: - Source

public enum SourceType: String, Sendable, Codable, Equatable, CaseIterable {
    case markdown
    case html
    case csv
    case jsonl
    case transcript
    case plainText
}

public struct KnowledgeSource: Sendable, Codable, Equatable {
    public let id: String
    public let type: SourceType
    public let path: String
    public let title: String?
    public let metadata: [String: String]?
    public let contentHash: String?
    public let lastIngested: String?
    public let sizeBytes: Int?

    public init(
        id: String,
        type: SourceType,
        path: String,
        title: String? = nil,
        metadata: [String: String]? = nil,
        contentHash: String? = nil,
        lastIngested: String? = nil,
        sizeBytes: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.title = title
        self.metadata = metadata
        self.contentHash = contentHash
        self.lastIngested = lastIngested
        self.sizeBytes = sizeBytes
    }
}

// MARK: - Extracted claims / entities

public struct ExtractedClaim: Sendable, Codable, Equatable {
    public let id: String
    public let text: String
    public let entities: [String]
    public let sourceId: String
    public let sourceSpan: SourceSpan
    public let confidence: Double
    public let timestamp: String?
    public let section: String?

    public struct SourceSpan: Sendable, Codable, Equatable {
        public let start: Int
        public let end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    public init(
        id: String,
        text: String,
        entities: [String] = [],
        sourceId: String,
        sourceSpan: SourceSpan,
        confidence: Double = 1.0,
        timestamp: String? = nil,
        section: String? = nil
    ) {
        self.id = id
        self.text = text
        self.entities = entities
        self.sourceId = sourceId
        self.sourceSpan = sourceSpan
        self.confidence = confidence
        self.timestamp = timestamp
        self.section = section
    }
}

public struct ExtractedEntity: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let kind: String?     // "person", "place", "concept", ...
    public let aliases: [String]
    public let mentionCount: Int

    public init(id: String, name: String, kind: String? = nil, aliases: [String] = [], mentionCount: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.aliases = aliases
        self.mentionCount = mentionCount
    }
}

public struct ExtractedRelationship: Sendable, Codable, Equatable {
    public let from: String       // entity id
    public let to: String         // entity id
    public let label: String
    public let claimId: String

    public init(from: String, to: String, label: String, claimId: String) {
        self.from = from
        self.to = to
        self.label = label
        self.claimId = claimId
    }
}

// MARK: - Wiki output

public struct WikiPage: Sendable, Codable, Equatable {
    public let slug: String
    public let title: String
    public let content: String
    public let pageType: PageType
    public let claimIds: [String]
    public let entityIds: [String]
    public let inboundLinks: [String]
    public let outboundLinks: [String]
    public let sourceIds: [String]
    public let lastUpdated: String
    public let tokenCount: Int

    public enum PageType: String, Sendable, Codable, Equatable {
        case entity, topic, index, log
    }

    public init(
        slug: String,
        title: String,
        content: String,
        pageType: PageType,
        claimIds: [String] = [],
        entityIds: [String] = [],
        inboundLinks: [String] = [],
        outboundLinks: [String] = [],
        sourceIds: [String] = [],
        lastUpdated: String,
        tokenCount: Int = 0
    ) {
        self.slug = slug
        self.title = title
        self.content = content
        self.pageType = pageType
        self.claimIds = claimIds
        self.entityIds = entityIds
        self.inboundLinks = inboundLinks
        self.outboundLinks = outboundLinks
        self.sourceIds = sourceIds
        self.lastUpdated = lastUpdated
        self.tokenCount = tokenCount
    }
}

// MARK: - KnowledgeBase

public struct KnowledgeBase: Sendable, Codable, Equatable {
    public let version: String
    public let compiledAt: String
    public let sources: [KnowledgeSource]
    public let pages: [WikiPage]
    public let claims: [ExtractedClaim]
    public let entities: [ExtractedEntity]
    public let relationships: [ExtractedRelationship]
    public let contradictions: [Contradiction]

    public struct Contradiction: Sendable, Codable, Equatable {
        public let claimAId: String
        public let claimBId: String
        public let reason: String

        public init(claimAId: String, claimBId: String, reason: String) {
            self.claimAId = claimAId
            self.claimBId = claimBId
            self.reason = reason
        }
    }

    public init(
        version: String = "0.5.0",
        compiledAt: String,
        sources: [KnowledgeSource] = [],
        pages: [WikiPage] = [],
        claims: [ExtractedClaim] = [],
        entities: [ExtractedEntity] = [],
        relationships: [ExtractedRelationship] = [],
        contradictions: [Contradiction] = []
    ) {
        self.version = version
        self.compiledAt = compiledAt
        self.sources = sources
        self.pages = pages
        self.claims = claims
        self.entities = entities
        self.relationships = relationships
        self.contradictions = contradictions
    }
}
