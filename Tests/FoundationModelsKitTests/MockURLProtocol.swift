import Foundation

/// Intercepts `URLSession` traffic so backends can be tested without a network
/// or an API key.
///
/// Every request is recorded, so tests can assert on what was *sent* — URL,
/// headers, body — not just on what came back.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    struct Stub {
        var statusCode: Int = 200
        var body: Data = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]
        /// Set to fail at the transport layer rather than with an HTTP status.
        var error: Error?

        static func json(_ string: String, status: Int = 200) -> Stub {
            Stub(statusCode: status, body: Data(string.utf8))
        }

        /// Server-sent events. Lines are joined with the blank-line separator
        /// real SSE uses, so parsing is exercised the way it is in production.
        static func sse(_ events: [String]) -> Stub {
            Stub(
                statusCode: 200,
                body: Data(events.map { "data: \($0)\n\n" }.joined().utf8),
                headers: ["Content-Type": "text/event-stream"]
            )
        }
    }

    /// Guards the stub queue and the recorded requests. `URLProtocol` is
    /// instantiated by the loading system on arbitrary threads.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    /// Installs stubs, newest request served first, and clears history.
    static func reset(with stubs: [Stub]) {
        lock.lock(); defer { lock.unlock() }
        self.stubs = stubs
        self.recorded = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Bodies as sent. `URLProtocol` strips `httpBody` for streamed uploads,
    /// so this reads `httpBodyStream` when needed.
    static func requestBodies() -> [Data] {
        requests.map { request in
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    /// A `URLSession` wired to this protocol. Ephemeral so nothing is cached
    /// between tests.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func nextStub() -> Stub {
        lock.lock(); defer { lock.unlock() }
        // The last stub repeats, so a multi-turn loop does not need one stub
        // per turn unless the test cares about the difference.
        return stubs.count > 1 ? stubs.removeFirst() : (stubs.first ?? Stub())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()

        let stub = Self.nextStub()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
