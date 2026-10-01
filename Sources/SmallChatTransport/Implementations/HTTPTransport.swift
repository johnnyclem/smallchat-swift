import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP transport implementation using URLSession.
///
/// Supports standard REST APIs with:
///   - Auth strategies (Bearer, OAuth2)
///   - Retry with exponential backoff
///   - Circuit breaker
///   - Configurable timeouts
///   - Streaming (SSE, NDJSON) via `URLSession.streamingBytes(for:)`
///   - Connection pooling
///
/// Mirrors the TypeScript `HttpTransport` class.
public actor HTTPTransport: Transport {

    public nonisolated let id: String

    private let config: TransportConfig
    private let session: URLSession
    private let retryMiddleware: RetryMiddleware?
    private let circuitBreaker: CircuitBreaker?
    private let timeoutMiddleware: TimeoutMiddleware
    private let pool: ConnectionPool

    /// Route mappings: tool name -> route info.
    private var routes: [String: HTTPTransportRoute] = [:]
    private var connected: Bool = true

    private static let ids = TransportIDSequence(prefix: "http")

    public init(config: TransportConfig) {
        let id = Self.ids.next()
        self.id = id
        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.httpMaximumConnectionsPerHost = config.poolSize
        self.session = URLSession(configuration: sessionConfig)

        self.retryMiddleware = config.retryConfig.map { RetryMiddleware(config: $0) }
        self.circuitBreaker = config.circuitBreakerConfig.map {
            CircuitBreaker(transportId: id, config: $0)
        }
        self.timeoutMiddleware = TimeoutMiddleware(timeout: config.timeout)
        self.pool = ConnectionPool(maxConnections: config.poolSize)
    }

    // MARK: - Route Management

    /// Register a route mapping for a tool name.
    public func addRoute(_ route: HTTPTransportRoute) {
        routes[route.toolName] = route
    }

    /// Register multiple routes.
    public func addRoutes(_ newRoutes: [HTTPTransportRoute]) {
        for route in newRoutes {
            routes[route.toolName] = route
        }
    }

    // MARK: - Transport Protocol

    public nonisolated var isConnected: Bool {
        get async { await getConnected() }
    }

    private func getConnected() -> Bool { connected }

    public nonisolated func connect() async throws {
        // URLSession is always ready
    }

    public nonisolated func disconnect() async throws {
        await performDisconnect()
    }

    private func performDisconnect() {
        session.invalidateAndCancel()
        connected = false
    }

    public nonisolated func execute(input: TransportInput) async throws -> TransportOutput {
        let startTime = Date()

        do {
            let result = try await executeWithMiddleware(input)
            var output = result
            output.metadata["durationMs"] = String(Int(Date().timeIntervalSince(startTime) * 1000))
            return output
        } catch {
            var output = errorToTransportOutput(error)
            output.metadata["durationMs"] = String(Int(Date().timeIntervalSince(startTime) * 1000))
            return output
        }
    }

    public nonisolated func executeStream(input: TransportInput) -> AsyncThrowingStream<TransportOutput, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let startTime = Date()
                do {
                    let request = try await self.buildURLRequest(input)
                    var mutRequest = request
                    mutRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await self.session.streamingBytes(for: mutRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.yield(errorToTransportOutput(
                            TransportError.invalidResponse(message: "Non-HTTP response")
                        ))
                        continuation.finish()
                        return
                    }

                    if httpResponse.statusCode >= 400 {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        continuation.yield(TransportOutput(
                            statusCode: httpResponse.statusCode,
                            headers: Self.extractHeaders(httpResponse),
                            body: body,
                            metadata: ["isError": "true"]
                        ))
                        continuation.finish()
                        return
                    }

                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                    var chunkIndex = 0

                    if contentType.contains("text/event-stream") {
                        let parser = SSEParser(source: bytes)
                        for try await event in parser {
                            let output = TransportOutput(
                                statusCode: 200,
                                headers: [:],
                                body: Data(event.data.utf8),
                                metadata: [
                                    "streaming": "true",
                                    "chunkIndex": String(chunkIndex),
                                    "durationMs": String(Int(Date().timeIntervalSince(startTime) * 1000)),
                                ]
                            )
                            chunkIndex += 1
                            continuation.yield(output)
                        }
                    } else if contentType.contains("application/x-ndjson") || contentType.contains("application/jsonl") {
                        let parser = NDJSONParser(source: bytes)
                        for try await data in parser {
                            let output = TransportOutput(
                                statusCode: 200,
                                headers: [:],
                                body: data,
                                metadata: [
                                    "streaming": "true",
                                    "chunkIndex": String(chunkIndex),
                                ]
                            )
                            chunkIndex += 1
                            continuation.yield(output)
                        }
                    } else {
                        // Raw text chunks
                        var buffer = Data()
                        for try await byte in bytes {
                            buffer.append(byte)
                            if byte == UInt8(ascii: "\n") {
                                let output = TransportOutput(
                                    statusCode: 200,
                                    headers: [:],
                                    body: buffer,
                                    metadata: [
                                        "streaming": "true",
                                        "chunkIndex": String(chunkIndex),
                                    ]
                                )
                                chunkIndex += 1
                                continuation.yield(output)
                                buffer = Data()
                            }
                        }
                        if !buffer.isEmpty {
                            continuation.yield(TransportOutput(
                                statusCode: 200,
                                headers: [:],
                                body: buffer,
                                metadata: ["streaming": "true", "chunkIndex": String(chunkIndex)]
                            ))
                        }
                    }

                    continuation.finish()
                } catch {
                    var output = errorToTransportOutput(error)
                    output.metadata["durationMs"] = String(Int(Date().timeIntervalSince(startTime) * 1000))
                    continuation.yield(output)
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Private

    private func executeWithMiddleware(_ input: TransportInput) async throws -> TransportOutput {
        let doRequest: @Sendable (Int) async throws -> TransportOutput = { [self] attempt in
            let innerFn: @Sendable () async throws -> TransportOutput = { [self] in
                let request = try await self.buildURLRequest(input)
                let effectiveTimeout = input.timeout ?? self.config.timeout

                let output: TransportOutput = try await self.timeoutMiddleware.execute(timeout: effectiveTimeout) {
                    let (data, response) = try await self.session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TransportError.invalidResponse(message: "Non-HTTP response")
                    }

                    return TransportOutput(
                        statusCode: httpResponse.statusCode,
                        headers: Self.extractHeaders(httpResponse),
                        body: data,
                        metadata: ["attempt": String(attempt)]
                    )
                }

                // Throw on error status so retry can catch it
                if output.statusCode >= 400 && self.retryMiddleware != nil {
                    throw TransportError.fromHTTPStatus(output.statusCode, body: output.bodyString)
                }

                return output
            }

            if let cb = self.circuitBreaker {
                return try await cb.execute(innerFn)
            }
            return try await innerFn()
        }

        if let retry = retryMiddleware {
            return try await retry.execute(doRequest)
        }
        return try await doRequest(0)
    }

    private func buildURLRequest(_ input: TransportInput) async throws -> URLRequest {
        let route = await getRoute(for: input.toolName)
        let method = input.method ?? route?.method ?? config.defaultMethod
        let path = input.url ?? route?.path ?? input.toolName

        // Fill `{param}` placeholders, put query (and, for GET, undeclared)
        // params in the query string, and the rest in a JSON body.
        let serialized = try TransportSerialization.serializeInput(
            baseURL: config.baseURL.absoluteString,
            path: path,
            method: method,
            args: input.args,
            route: route
        )
        guard let url = URL(string: serialized.url) else {
            throw TransportError.invalidRequest(message: "Invalid URL: \(serialized.url)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        // Merge headers: config defaults < route headers < input headers
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in serialized.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in input.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // A pre-serialized body wins over the arguments.
        request.httpBody = input.body ?? serialized.body

        // Apply auth
        if let auth = config.auth {
            var transportInput = input
            try await auth.authenticate(request: &transportInput)
            for (key, value) in transportInput.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return request
    }

    private func getRoute(for toolName: String) -> HTTPTransportRoute? {
        routes[toolName]
    }

    nonisolated static func extractHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }
        return headers
    }
}

// MARK: - HTTPTransportRoute

/// Route mapping for an HTTP transport tool.
public struct HTTPTransportRoute: Sendable {
    public let toolName: String
    public let method: HTTPMethod
    public let path: String
    public let queryParams: [String]?
    public let pathParams: [String]?
    public let bodyParams: [String]?
    public let headers: [String: String]?

    public init(
        toolName: String,
        method: HTTPMethod,
        path: String,
        queryParams: [String]? = nil,
        pathParams: [String]? = nil,
        bodyParams: [String]? = nil,
        headers: [String: String]? = nil
    ) {
        self.toolName = toolName
        self.method = method
        self.path = path
        self.queryParams = queryParams
        self.pathParams = pathParams
        self.bodyParams = bodyParams
        self.headers = headers
    }
}
