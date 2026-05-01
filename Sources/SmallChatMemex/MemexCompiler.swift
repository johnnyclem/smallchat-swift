import Foundation
import SmallChatCore
import SmallChatShorthand

// MARK: - SmallChatMemex compiler
//
// Five-stage pipeline: READ -> EXTRACT -> EMBED -> LINK -> EMIT.
//
// This Swift port implements the deterministic pieces (sentence-level
// claim extraction, capitalised-noun entity surfacing, entity-page
// emission, contradiction detection via the same negation heuristic the
// SmallChatCompaction module uses). Real semantic claim extraction
// requires an LLM and is left as a hook callers can supply.

// MARK: - Configuration

public struct MemexConfig: Sendable {
    public let now: () -> Date
    public let minClaimLength: Int

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        minClaimLength: Int = 20
    ) {
        self.now = now
        self.minClaimLength = minClaimLength
    }
}

// MARK: - Compiler

public struct MemexCompiler: Sendable {
    public let config: MemexConfig

    public init(config: MemexConfig = MemexConfig()) {
        self.config = config
    }

    /// Compile a set of textual sources into a `KnowledgeBase`.
    ///
    /// Each input is a `(KnowledgeSource, body)` pair: the metadata
    /// alongside the raw text content of the source. The pipeline does
    /// not touch the file system itself, so the same compiler is usable
    /// from a CLI, a test, or a GUI live-edit pane.
    public func compile(_ inputs: [(KnowledgeSource, String)]) -> KnowledgeBase {

        // Stage 1: READ -- normalize sources, attach a content hash.
        let sources: [KnowledgeSource] = inputs.map { (src, body) in
            KnowledgeSource(
                id: src.id,
                type: src.type,
                path: src.path,
                title: src.title,
                metadata: src.metadata,
                contentHash: Shorthand.contentHashHex(body),
                lastIngested: ISO8601DateFormatter().string(from: config.now()),
                sizeBytes: body.utf8.count
            )
        }

        // Stage 2: EXTRACT -- claims (sentence-level) and entities
        // (capitalised multi-letter words).
        var claims: [ExtractedClaim] = []
        var entityCounter: [String: ExtractedEntity] = [:]

        for (src, body) in inputs {
            let sentences = Shorthand.sentences(in: body)
            var cursor = 0
            for sentence in sentences {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count < config.minClaimLength { continue }

                let entityNames = surfaceEntities(from: trimmed)
                for name in entityNames {
                    let id = entityId(for: name)
                    let existing = entityCounter[id]
                    entityCounter[id] = ExtractedEntity(
                        id: id,
                        name: name,
                        kind: existing?.kind,
                        aliases: existing?.aliases ?? [],
                        mentionCount: (existing?.mentionCount ?? 0) + 1
                    )
                }

                let claimId = "\(src.id)#\(claims.count)"
                let span = ExtractedClaim.SourceSpan(start: cursor, end: cursor + trimmed.count)
                claims.append(ExtractedClaim(
                    id: claimId,
                    text: trimmed,
                    entities: entityNames.map(entityId(for:)),
                    sourceId: src.id,
                    sourceSpan: span,
                    confidence: 0.85
                ))
                cursor += trimmed.count
            }
        }

        let entities = Array(entityCounter.values).sorted { $0.id < $1.id }

        // Stage 3: EMBED -- omitted from the pure pipeline; callers wire
        // a real embedder via SmallChatEmbedding when they need it.

        // Stage 4: LINK -- relationships derived from claim co-mentions:
        // any two entities that appear in the same claim get a co-mention
        // edge labelled "co-mentioned".
        var relationships: [ExtractedRelationship] = []
        for c in claims {
            let ids = c.entities
            if ids.count < 2 { continue }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    relationships.append(ExtractedRelationship(
                        from: ids[i],
                        to: ids[j],
                        label: "co-mentioned",
                        claimId: c.id
                    ))
                }
            }
        }

        // Stage 5: EMIT -- one wiki page per entity, plus an index page.
        let now = ISO8601DateFormatter().string(from: config.now())
        var pages: [WikiPage] = []

        for entity in entities {
            let related = claims.filter { $0.entities.contains(entity.id) }
            let body = related.map(\.text).joined(separator: "\n\n")
            let outbound = Set(related.flatMap(\.entities)).subtracting([entity.id])
            pages.append(WikiPage(
                slug: entity.id,
                title: entity.name,
                content: body,
                pageType: .entity,
                claimIds: related.map(\.id),
                entityIds: [entity.id],
                inboundLinks: [],
                outboundLinks: outbound.sorted(),
                sourceIds: Array(Set(related.map(\.sourceId))).sorted(),
                lastUpdated: now,
                tokenCount: Shorthand.tokens(in: body).count
            ))
        }

        // Index page lists every entity.
        let indexBody = entities
            .map { "- [\($0.name)](#\($0.id)) (\($0.mentionCount) mentions)" }
            .joined(separator: "\n")
        pages.append(WikiPage(
            slug: "index",
            title: "Index",
            content: indexBody,
            pageType: .index,
            entityIds: entities.map(\.id),
            lastUpdated: now,
            tokenCount: Shorthand.tokens(in: indexBody).count
        ))

        // Inbound link backfill.
        pages = pages.map { page in
            let inbound = pages.filter { $0.outboundLinks.contains(page.slug) }.map(\.slug)
            return WikiPage(
                slug: page.slug,
                title: page.title,
                content: page.content,
                pageType: page.pageType,
                claimIds: page.claimIds,
                entityIds: page.entityIds,
                inboundLinks: inbound,
                outboundLinks: page.outboundLinks,
                sourceIds: page.sourceIds,
                lastUpdated: page.lastUpdated,
                tokenCount: page.tokenCount
            )
        }

        // Contradictions: deterministic literal-negation pass over claims.
        let contradictions = detectContradictions(claims: claims)

        return KnowledgeBase(
            version: "0.5.0",
            compiledAt: now,
            sources: sources,
            pages: pages,
            claims: claims,
            entities: entities,
            relationships: relationships,
            contradictions: contradictions
        )
    }

    // MARK: - Heuristics

    /// Surface "entities" by collecting capitalised multi-letter words.
    /// Conservative -- the goal is recall on names, not perfection.
    private func surfaceEntities(from sentence: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in sentence {
            if ch.isLetter || ch == "-" {
                cur.append(ch)
            } else {
                if cur.count >= 3, let first = cur.first, first.isUppercase {
                    out.append(cur)
                }
                cur = ""
            }
        }
        if cur.count >= 3, let first = cur.first, first.isUppercase {
            out.append(cur)
        }
        // Dedupe preserving order.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private func entityId(for name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    /// Conservative literal-negation detector, mirroring the contradiction
    /// strategy in SmallChatCompaction. Catches obvious flips (X vs not X)
    /// rather than philosophical disagreements.
    private func detectContradictions(claims: [ExtractedClaim]) -> [KnowledgeBase.Contradiction] {
        var out: [KnowledgeBase.Contradiction] = []
        let negations = ["not ", " no ", "never ", "isn't", "aren't", "doesn't", "don't"]
        for i in 0..<claims.count {
            for j in (i + 1)..<claims.count {
                let a = claims[i].text.lowercased()
                let b = claims[j].text.lowercased()
                let aTok = Set(Shorthand.tokens(in: a))
                let bTok = Set(Shorthand.tokens(in: b))
                if aTok.isEmpty || bTok.isEmpty { continue }
                let overlap = Shorthand.jaccard(aTok, bTok)
                if overlap < 0.5 { continue }
                let aHasNeg = negations.contains { a.contains($0) }
                let bHasNeg = negations.contains { b.contains($0) }
                if aHasNeg != bHasNeg {
                    out.append(.init(
                        claimAId: claims[i].id,
                        claimBId: claims[j].id,
                        reason: "literal-negation mismatch with token overlap \(String(format: "%.2f", overlap))"
                    ))
                }
            }
        }
        return out
    }
}

// MARK: - Resolver

/// Entity-name lookup over a compiled `KnowledgeBase`. Returns the
/// matching `WikiPage` plus a `DispatchTier`-equivalent confidence so the
/// resolver behaves like the dispatch pipeline.
public struct MemexResolver: Sendable {
    public let knowledgeBase: KnowledgeBase

    public init(knowledgeBase: KnowledgeBase) {
        self.knowledgeBase = knowledgeBase
    }

    public struct Hit: Sendable, Equatable {
        public let page: WikiPage
        public let confidence: Double
    }

    /// Best-effort lookup. Returns up to `limit` ranked hits; empty when
    /// the query has no overlap with any indexed entity.
    public func query(_ q: String, limit: Int = 5) -> [Hit] {
        let queryTokens = Set(Shorthand.tokens(in: q))
        guard !queryTokens.isEmpty else { return [] }

        var scored: [Hit] = []
        for page in knowledgeBase.pages where page.pageType == .entity {
            let nameTokens = Set(Shorthand.tokens(in: page.title))
            let bodyTokens = Set(Shorthand.tokens(in: page.content))
            let nameSim = Shorthand.jaccard(queryTokens, nameTokens)
            let bodySim = Shorthand.jaccard(queryTokens, bodyTokens)
            let confidence = max(nameSim, 0.5 * nameSim + 0.5 * bodySim)
            if confidence > 0 {
                scored.append(Hit(page: page, confidence: confidence))
            }
        }
        return scored
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { $0 }
    }
}
