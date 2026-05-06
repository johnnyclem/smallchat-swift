import SmallChatCore

/// AppCompiler -- build-time compiler that produces an `AppArtifact` from `AppManifest` values.
///
/// Parallel to `ToolCompiler` with the same 4-phase pipeline:
///   PARSE → EMBED → LINK → EMIT
///
/// The output is a `CompilationResult` with `.appArtifact` populated; the tool-level
/// fields (`selectors`, `dispatchTables`, etc.) are left at their zero values since
/// this compiler operates exclusively on the App/UI layer.
public struct AppCompiler: Sendable {
    private let embedder: any Embedder
    private let vectorIndex: any VectorIndex

    public init(embedder: any Embedder, vectorIndex: any VectorIndex) {
        self.embedder = embedder
        self.vectorIndex = vectorIndex
    }

    /// Compile a list of `AppManifest` values into a `CompilationResult`.
    ///
    /// - Phase 1 PARSE: Extract components and resolve `uiResourceUri` to HTML strings.
    /// - Phase 2 EMBED: Produce a `ComponentSelector` for each component via `ComponentSelectorTable`.
    /// - Phase 3 LINK: Build one `AppClass` per manifest; populate its dispatch table.
    /// - Phase 4 EMIT: Serialize to `AppArtifact`, attach to `CompilationResult`.
    public func compile(_ manifests: [AppManifest]) async throws -> CompilationResult {
        // Phase 1: PARSE
        struct ParsedComponent {
            let appId: String
            let canonical: String
            let intentText: String
            let uri: String
        }

        var parsedComponents: [ParsedComponent] = []
        var embeddedHTML: [String: String] = [:]

        for manifest in manifests {
            let html = resolveUIResourceUri(manifest.uiResourceUri)
            let uiUri = uiURIForApp(manifest.id)

            if let html {
                embeddedHTML[uiUri] = html
            }

            // Entry-point component: the app itself is a component
            let entryCanonical = "\(manifest.id).entry"
            parsedComponents.append(ParsedComponent(
                appId: manifest.id,
                canonical: entryCanonical,
                intentText: "open \(manifest.name)",
                uri: uiUri
            ))

            // Declared sub-components
            for component in manifest.components {
                let canonical = "\(manifest.id).\(component.name)"
                let intentText = component.intentText ?? component.description
                let uri = "\(uiUri)#\(component.name)"
                parsedComponents.append(ParsedComponent(
                    appId: manifest.id,
                    canonical: canonical,
                    intentText: intentText,
                    uri: uri
                ))
            }
        }

        // Phase 2: EMBED
        let selectorTable = ComponentSelectorTable(
            index: vectorIndex,
            embedder: embedder,
            threshold: 0.95
        )

        var componentSelectors: [String: ComponentSelector] = [:]
        for component in parsedComponents {
            let embedding = try await embedder.embed(component.intentText)
            let selector = try await selectorTable.intern(
                embedding: embedding,
                canonical: component.canonical,
                intentText: component.intentText
            )
            componentSelectors[component.canonical] = selector
        }

        // Phase 3: LINK
        var appClasses: [String: AppClass] = [:]

        for manifest in manifests {
            let appClass = AppClass(
                appId: manifest.id,
                name: manifest.name,
                uiResourceUri: manifest.uiResourceUri
            )
            let manifestComponents = parsedComponents.filter { $0.appId == manifest.id }
            for component in manifestComponents {
                appClass.addComponent(component.canonical, uri: component.uri)
            }
            appClasses[manifest.id] = appClass
        }

        // Phase 4: EMIT
        var appClassData: [String: AppClassData] = [:]
        var uriMap: [String: String] = [:]

        for (appId, appClass) in appClasses {
            let selectors = Array(appClass.dispatchTable.keys)
            appClassData[appId] = AppClassData(
                appId: appId,
                name: appClass.name,
                uiResourceUri: appClass.uiResourceUri,
                componentSelectors: selectors
            )
            for canonical in selectors {
                if let uri = appClass.resolveComponent(canonical) {
                    uriMap[canonical] = uri
                }
            }
        }

        let artifact = AppArtifact(
            appClasses: appClassData,
            embeddedHTML: embeddedHTML,
            uriMap: uriMap,
            appCount: manifests.count
        )

        return CompilationResult(appArtifact: artifact)
    }
}

// MARK: - Helpers

/// Resolve the `uiResourceUri` field to an HTML string.
/// Inline HTML (starts with `<`) is returned as-is.
/// `file://` paths are read from disk.
/// All other values are treated as inline HTML.
private func resolveUIResourceUri(_ uriOrHTML: String?) -> String? {
    guard let value = uriOrHTML, !value.isEmpty else { return nil }

    if value.hasPrefix("<") {
        return value
    }

    if value.hasPrefix("file://") {
        let path = String(value.dropFirst("file://".count))
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    // Treat anything else as a raw HTML string
    return value
}

/// Canonical `ui://` URI for an app's entry-point HTML.
private func uiURIForApp(_ appId: String) -> String {
    "ui://\(appId)/index.html"
}
