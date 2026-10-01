import SmallChatCore

/// Two distinct tools embed at or above the duplicate threshold. The
/// compiler never merges tools; it refuses to build a toolkit whose intents
/// could not tell them apart, unless `allowDuplicates` is set.
public struct DuplicateToolError: Error, Sendable, CustomStringConvertible {
    public let pairs: [DuplicateToolPair]
    public let threshold: Double

    public var description: String {
        let lines = pairs.map {
            "  \($0.toolA) <-> \($0.toolB) (cosine \(String(format: "%.3f", $0.similarity)); selectors \($0.selectorA), \($0.selectorB))"
        }
        return "\(pairs.count) pair(s) of distinct tools embed at cosine >= \(threshold) and cannot be told apart:\n"
            + lines.joined(separator: "\n") + "\n"
            + "Disambiguate them with compiler hints (selectorHint, aliases, exclude), or pass "
            + "allowDuplicates (--allow-duplicates) to keep every tool and accept ambiguous intent resolution."
    }
}

/// Two tools claim the same selector canonical (a pinSelector or namespace
/// clash), the same alias phrase, or the same tool id. One selector
/// dispatches to exactly one tool, so this cannot be waived.
public struct SelectorConflictError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// ToolCompiler -- build-time tool that produces dispatch tables, selector tables, etc.
/// Pipeline: PARSE -> EMBED -> LINK -> OUTPUT
///
/// Same semantics as @smallchat/core 1.0's compiler: every tool gets its
/// own selector under its exact canonical (`<providerId>.<name>`, or the
/// `pinSelector` / provider `namespace` hint); the primary selector embeds
/// `<name>: <description>[ <selectorHint>]`; each alias is its own selector
/// (`<canonical>~alias~<alias_with_underscores>`); tools are never merged,
/// and duplicates (cosine >= `duplicateThreshold`) are an error unless
/// allowed. Feed the result to `ArtifactV1.build` to write artifact format 1.0.
public struct ToolCompiler: Sendable {
    private let embedder: any Embedder
    private let vectorIndex: any VectorIndex
    private let options: CompilerOptions

    public init(embedder: any Embedder, vectorIndex: any VectorIndex, options: CompilerOptions = CompilerOptions()) {
        self.embedder = embedder
        self.vectorIndex = vectorIndex
        self.options = options
    }

    /// Compile tool definitions from provider manifests
    public func compile(_ manifests: [ProviderManifest]) async throws -> CompilationResult {
        // Phase 1: PARSE (tools excluded by compiler hints are dropped)
        var allTools: [ParsedTool] = []
        for manifest in manifests {
            allTools.append(contentsOf: parseMCPManifest(manifest))
        }

        // Phase 2: EMBED -- every tool gets its own selector; a selector is
        // never shared between tools, whatever the embeddings say.
        let selectorTable = SelectorTable(index: vectorIndex, embedder: embedder)
        var registered: [ToolSelector] = []
        var selectorOwners: [String: String] = [:]          // canonical -> tool id
        var aliasOwners: [String: (id: String, alias: String)] = [:]  // normalized phrase -> owner
        var toolIds: [String] = []
        var seenToolIds = Set<String>()
        var toolSelectors: [Int: ToolSelector] = [:]
        var toolEmbeddings: [Int: [Float]] = [:]
        var aliasSelectors: [Int: [ToolSelector]] = [:]
        var aliasCanonicals = Set<String>()
        var toolRefs: [CompiledToolRef] = []

        func claim(_ canonical: String, _ id: String, _ embedding: [Float]) async throws -> ToolSelector {
            if let owner = selectorOwners[canonical], owner != id {
                throw SelectorConflictError(message:
                    "Selector \"\(canonical)\" is claimed by both \(owner) and \(id). "
                    + "Each tool needs its own selector — change the pinSelector, namespace, or alias.")
            }
            let isNew = selectorOwners[canonical] == nil
            selectorOwners[canonical] = id
            let selector = try await selectorTable.register(embedding: embedding, canonical: canonical)
            if isNew { registered.append(selector) }
            return selector
        }

        for (i, tool) in allTools.enumerated() {
            let id = try makeToolId(providerId: tool.providerId, toolName: tool.name)
            guard seenToolIds.insert(id).inserted else {
                throw SelectorConflictError(message:
                    "Tool id \"\(id)\" is declared more than once — tool names must be unique within a provider.")
            }
            toolIds.append(id)

            let canonical: String
            if let pinned = tool.compilerHints?.pinnedSelector {
                canonical = pinned
            } else if let namespace = tool.providerHints?.namespacePrefix {
                canonical = "\(namespace).\(tool.name)"
            } else {
                canonical = "\(tool.providerId).\(tool.name)"
            }

            let embedding = try await embedder.embed(tool.embeddingText)
            toolEmbeddings[i] = embedding
            toolSelectors[i] = try await claim(canonical, id, embedding)

            // Each alias gets its own selector pointing to the same tool.
            var aliases: [ToolSelector] = []
            var seenAliases = Set<String>()
            for alias in tool.compilerHints?.aliases ?? [] where seenAliases.insert(alias).inserted {
                // One phrase, one tool: two tools sharing an alias would embed
                // it identically and tie on every intent near it.
                let phrase = normalizePinPhrase(alias)
                if let other = aliasOwners[phrase], other.id != id {
                    throw SelectorConflictError(message:
                        "Alias \"\(alias)\" of \(id) is also an alias of \(other.id) (\"\(other.alias)\"). "
                        + "An alias phrase can belong to only one tool; remove it from one of them.")
                }
                aliasOwners[phrase] = (id, alias)
                let aliasEmbedding = try await embedder.embed(alias)
                let aliasCanonical = "\(canonical)~alias~\(underscoreWhitespace(alias))"
                let aliasSelector = try await claim(aliasCanonical, id, aliasEmbedding)
                aliases.append(aliasSelector)
                aliasCanonicals.insert(aliasCanonical)
            }
            if !aliases.isEmpty { aliasSelectors[i] = aliases }

            toolRefs.append(CompiledToolRef(
                id: id,
                providerId: tool.providerId,
                toolName: tool.name,
                selector: canonical,
                aliases: aliases.map(\.canonical)
            ))
        }

        // Phase 2.5: SEMANTIC OVERLOAD GENERATION (optional)
        var overloadTables: [String: OverloadTableData] = [:]
        var semanticOverloads: [SemanticOverloadGroup] = []
        // Tool id -> overload group: tools in one group are deliberately
        // similar, so they are exempt from duplicate detection.
        var overloadGroupOf: [String: Int] = [:]

        if options.generateSemanticOverloads {
            let groups = findSemanticGroups(
                tools: allTools,
                embeddings: toolEmbeddings,
                threshold: options.semanticOverloadThreshold
            )

            for (groupIndex, group) in groups.enumerated() {
                for tool in group.tools { overloadGroupOf["\(tool.providerId)/\(tool.name)"] = groupIndex }
                let canonicalSelector = "\(group.tools[0].providerId).\(group.tools[0].name)"
                var overloadEntries: [OverloadEntryData] = []

                for tool in group.tools {
                    let slots = toolArgsToParameterSlots(tool)
                    let sig = createSignature(slots)
                    overloadEntries.append(OverloadEntryData(
                        signatureKey: sig.signatureKey,
                        parameterNames: slots.map(\.name),
                        parameterTypes: slots.map { typeDescriptorToString($0.type) },
                        arity: sig.arity,
                        toolName: tool.name,
                        providerId: tool.providerId,
                        isSemanticOverload: true
                    ))
                }

                overloadTables[canonicalSelector] = OverloadTableData(
                    selectorCanonical: canonicalSelector,
                    overloads: overloadEntries
                )

                semanticOverloads.append(SemanticOverloadGroup(
                    canonicalSelector: canonicalSelector,
                    tools: group.tools.enumerated().map { i, t in
                        SemanticOverloadGroup.GroupedTool(
                            providerId: t.providerId,
                            toolName: t.name,
                            similarity: i == 0 ? 1.0 : group.similarities[i - 1]
                        )
                    },
                    reason: "Tools grouped by semantic similarity above \(Int(options.semanticOverloadThreshold * 100))% threshold"
                ))
            }
        }

        // Phase 2.6: DUPLICATE DETECTION -- distinct tools whose selectors
        // embed at or above the duplicate threshold. Reported once per tool
        // pair (its most similar selector pair), in compile order.
        var duplicateOrder: [String] = []
        var duplicatesByPair: [String: DuplicateToolPair] = [:]
        for i in 0..<registered.count {
            for j in (i + 1)..<registered.count {
                let a = registered[i], b = registered[j]
                let idA = selectorOwners[a.canonical]!, idB = selectorOwners[b.canonical]!
                if idA == idB { continue }
                if let groupA = overloadGroupOf[idA], groupA == overloadGroupOf[idB] { continue }
                let similarity = cosineSimilarityDouble(a.vector, b.vector)
                if similarity < options.duplicateThreshold { continue }
                let key = "\(idA)\u{0}\(idB)"
                if let previous = duplicatesByPair[key], previous.similarity >= similarity { continue }
                if duplicatesByPair[key] == nil { duplicateOrder.append(key) }
                duplicatesByPair[key] = DuplicateToolPair(toolA: idA, toolB: idB, selectorA: a.canonical, selectorB: b.canonical, similarity: similarity)
            }
        }
        let duplicates = duplicateOrder.compactMap { duplicatesByPair[$0] }
        if !duplicates.isEmpty && !options.allowDuplicates {
            throw DuplicateToolError(pairs: duplicates, threshold: options.duplicateThreshold)
        }

        // Phase 3: LINK -- dispatch tables (alias selectors reach the same IMP)
        var dispatchTables: [String: [String: any ToolIMP]] = [:]
        for (i, tool) in allTools.enumerated() {
            guard let selector = toolSelectors[i] else { continue }
            let imp = createIMP(tool)
            var table = dispatchTables[tool.providerId] ?? [:]
            table[selector.canonical] = imp
            for alias in aliasSelectors[i] ?? [] { table[alias.canonical] = imp }
            dispatchTables[tool.providerId] = table
        }

        // Collisions: pairs in the 0.75 - duplicateThreshold zone (skipping
        // overloaded and alias selectors) are reported, never errors.
        let firewallThreshold = 0.75
        let overloadedCanonicals = Set(overloadTables.keys)
        let preferred = Set(allTools.indices.compactMap { i -> String? in
            allTools[i].compilerHints?.preferred == true ? toolSelectors[i]?.canonical : nil
        })
        var collisions: [SelectorCollision] = []
        for i in 0..<registered.count {
            for j in (i + 1)..<registered.count {
                let a = registered[i], b = registered[j]
                if overloadedCanonicals.contains(a.canonical) || overloadedCanonicals.contains(b.canonical) { continue }
                if aliasCanonicals.contains(a.canonical) || aliasCanonicals.contains(b.canonical) { continue }

                let similarity = cosineSimilarityDouble(a.vector, b.vector)
                guard similarity > firewallThreshold && similarity < options.duplicateThreshold else { continue }

                let percent = String(format: "%.1f", similarity * 100)
                let aPreferred = preferred.contains(a.canonical)
                let bPreferred = preferred.contains(b.canonical)
                let hint: String
                if aPreferred && bPreferred {
                    hint = "Warning: both \"\(a.canonical)\" and \"\(b.canonical)\" are marked preferred — only one should be."
                } else if aPreferred {
                    hint = "\"\(a.canonical)\" is preferred (compiler hint) over \"\(b.canonical)\" (\(percent)% similar)."
                } else if bPreferred {
                    hint = "\"\(b.canonical)\" is preferred (compiler hint) over \"\(a.canonical)\" (\(percent)% similar)."
                } else if similarity < options.collisionThreshold {
                    hint = "Collision zone (\(percent)%): \"\(a.canonical)\" and \"\(b.canonical)\" — an intent near both may resolve to needs-disambiguation, or to the other tool. Consider distinct descriptions, a selectorHint, or calling them by tool id."
                } else {
                    hint = "Disambiguation needed: \"\(a.canonical)\" and \"\(b.canonical)\" are similar (\(percent)%)."
                }
                collisions.append(SelectorCollision(selectorA: a.canonical, selectorB: b.canonical, similarity: similarity, hint: hint))
            }
        }

        return CompilationResult(
            selectors: Dictionary(uniqueKeysWithValues: registered.map { ($0.canonical, $0) }),
            dispatchTables: dispatchTables,
            protocols: [],
            toolCount: allTools.count,
            uniqueSelectorCount: registered.count,
            mergedCount: 0,
            collisions: collisions,
            overloadTables: overloadTables,
            semanticOverloads: semanticOverloads,
            tools: toolRefs,
            duplicates: duplicates
        )
    }

    /// Build ToolClass instances from a compilation result
    public func buildClasses(_ result: CompilationResult) -> [ToolClass] {
        var classes: [ToolClass] = []
        for (providerId, table) in result.dispatchTables {
            let toolClass = ToolClass(name: providerId)
            for (canonical, imp) in table {
                if let selector = result.selectors[canonical] {
                    toolClass.addMethod(selector, imp: imp)
                }
            }
            classes.append(toolClass)
        }
        return classes
    }

    private func createIMP(_ tool: ParsedTool) -> ToolProxy {
        ToolProxy(
            providerId: tool.providerId,
            toolName: tool.name,
            transportType: tool.transportType,
            schemaLoader: { [tool] in
                ToolSchema(
                    name: tool.name,
                    description: tool.description,
                    inputSchema: tool.inputSchema,
                    arguments: tool.arguments
                )
            },
            annotations: tool.annotations
        )
    }
}

/// `alias.replace(/\s+/g, '_')`: every run of whitespace becomes one `_`.
private func underscoreWhitespace(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    var inRun = false
    for scalar in text.unicodeScalars {
        if isECMAScriptWhitespace(scalar) {
            if !inRun { out.append("_") }
            inRun = true
        } else {
            out.append(scalar)
            inRun = false
        }
    }
    return String(out)
}

private func typeDescriptorToString(_ type: SCTypeDescriptor) -> String {
    switch type {
    case .primitive(let p): return p.rawValue
    case .object(let className): return className
    case .union(let types): return types.map { typeDescriptorToString($0) }.joined(separator: " | ")
    case .any: return "id"
    }
}
