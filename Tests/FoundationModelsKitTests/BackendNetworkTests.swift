import Foundation
import Testing
@testable import FoundationModelsKit

// Network-layer tests for the HTTP backends. These exercise what is actually
// sent and how real payloads decode, without a network or an API key.

/// All of these share `MockURLProtocol`'s static stub queue, so they must not
/// run concurrently. `.serialized` on the parent applies to every nested suite.
@Suite("Backend networking", .serialized)
struct BackendNetworkTests {
    // MARK: - Shared plumbing

    @Suite("HTTP plumbing", .serialized)
    struct HTTPBackendSupportTests {

        @Test func transientStatusesAreRetryable() {
            for code in [408, 429, 500, 502, 503, 529, 599] {
                #expect(HTTPBackend.isTransient(statusCode: code), "\(code) should retry")
            }
        }

        @Test func clientErrorsAreNotRetryable() {
            for code in [400, 401, 403, 404, 409, 422] {
                #expect(!HTTPBackend.isTransient(statusCode: code), "\(code) must not retry")
            }
        }

        @Test func ssePayloadHandlesRealWorldLineShapes() {
            #expect(HTTPBackend.ssePayload(from: "data: {\"a\":1}") == "{\"a\":1}")
            #expect(HTTPBackend.ssePayload(from: "data:{\"a\":1}") == "{\"a\":1}")
            #expect(HTTPBackend.ssePayload(from: "data: [DONE]") == "[DONE]")
            // Non-payload lines providers interleave.
            #expect(HTTPBackend.ssePayload(from: "event: message_start") == nil)
            #expect(HTTPBackend.ssePayload(from: ": keep-alive") == nil)
            #expect(HTTPBackend.ssePayload(from: "") == nil)
            #expect(HTTPBackend.ssePayload(from: "data:") == nil)
            #expect(HTTPBackend.ssePayload(from: "data:   ") == nil)
        }

        @Test func terminatorIsRecognised() {
            #expect(HTTPBackend.isStreamTerminator("[DONE]"))
            #expect(!HTTPBackend.isStreamTerminator("{}"))
        }
    }

    // MARK: - Anthropic

    @Suite("Anthropic backend", .serialized)
    struct AnthropicBackendTests {

        private func makeModel(tools: [any ModelTool] = []) -> AnthropicLanguageModel {
            AnthropicLanguageModel(
                config: AnthropicConfiguration(apiKey: "sk-ant-test", model: "claude-opus-5-5"),
                tools: tools,
                session: MockURLProtocol.makeSession()
            )
        }

        private static let textResponse = """
        {"content":[{"type":"text","text":"Hello there"}],
         "stop_reason":"end_turn",
         "usage":{"input_tokens":12,"output_tokens":4}}
        """

        // MARK: Request construction

        @Test func sendsCorrectHeadersAndBody() async throws {
            MockURLProtocol.reset(with: [.json(Self.textResponse)])
            _ = try await makeModel().respond(to: ModelRequest(content: "Hi there"))

            let request = try #require(MockURLProtocol.requests.first)
            #expect(request.url?.path == "/v1/messages")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

            let body = try #require(MockURLProtocol.requestBodies().first)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["model"] as? String == "claude-opus-5-5")
            #expect(json?["stream"] == nil, "non-streaming request must not set stream")
            let messages = json?["messages"] as? [[String: Any]]
            #expect(messages?.first?["content"] as? String == "Hi there")
        }

        @Test func omitsToolsWhenNoneRegistered() async throws {
            MockURLProtocol.reset(with: [.json(Self.textResponse)])
            _ = try await makeModel().respond(to: ModelRequest(content: "Hi"))

            let body = try #require(MockURLProtocol.requestBodies().first)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["tools"] == nil)
        }

        @Test func sendsToolDefinitionsWhenRegistered() async throws {
            MockURLProtocol.reset(with: [.json(Self.textResponse)])
            _ = try await makeModel(tools: [EchoNetworkTool()]).respond(to: ModelRequest(content: "Hi"))

            let body = try #require(MockURLProtocol.requestBodies().first)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let tools = try #require(json?["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            #expect(tools[0]["name"] as? String == "echo")
            #expect(tools[0]["input_schema"] != nil)
        }

        // MARK: Decoding

        @Test func decodesTextAndUsage() async throws {
            MockURLProtocol.reset(with: [.json(Self.textResponse)])
            let response = try await makeModel().respond(to: ModelRequest(content: "Hi"))

            #expect(response.content == "Hello there")
            #expect(response.stopReason == "end_turn")
            #expect(response.usage.inputTokens == 12)
            #expect(response.usage.outputTokens == 4)
            #expect(!response.usage.isEstimated, "provider reported real counts")
        }

        @Test func joinsMultipleTextBlocks() async throws {
            MockURLProtocol.reset(with: [.json("""
            {"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}],
             "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
            """)])
            let response = try await makeModel().respond(to: ModelRequest(content: "Hi"))
            #expect(response.content == "one\ntwo")
        }

        @Test func toleratesResponseWithNoTextBlock() async throws {
            MockURLProtocol.reset(with: [.json("""
            {"content":[],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":0}}
            """)])
            let response = try await makeModel().respond(to: ModelRequest(content: "Hi"))
            #expect(response.content.isEmpty)
        }

        // MARK: Failure paths

        @Test func rateLimitBecomesUnavailableSoItRetries() async {
            MockURLProtocol.reset(with: [.json(#"{"error":"rate_limited"}"#, status: 429)])
            await #expect(throws: LanguageModelError.unavailable) {
                try await makeModel().respond(to: ModelRequest(content: "Hi"))
            }
        }

        @Test func overloadedBecomesUnavailable() async {
            MockURLProtocol.reset(with: [.json(#"{"error":"overloaded"}"#, status: 529)])
            await #expect(throws: LanguageModelError.unavailable) {
                try await makeModel().respond(to: ModelRequest(content: "Hi"))
            }
        }

        @Test func badRequestSurfacesServerDetail() async throws {
            MockURLProtocol.reset(with: [.json(#"{"error":{"message":"bad model"}}"#, status: 400)])
            do {
                _ = try await makeModel().respond(to: ModelRequest(content: "Hi"))
                Issue.record("expected a client error")
            } catch let error as AnthropicError {
                guard case .apiError(let status, let body) = error else {
                    Issue.record("wrong case: \(error)"); return
                }
                #expect(status == 400)
                #expect(body.contains("bad model"), "server detail should reach the caller")
            }
        }

        @Test func malformedJSONThrowsRatherThanReturningEmpty() async {
            MockURLProtocol.reset(with: [.json("not json at all")])
            await #expect(throws: (any Error).self) {
                try await makeModel().respond(to: ModelRequest(content: "Hi"))
            }
        }

        @Test func missingRequiredFieldThrows() async {
            // `usage` absent — decoding must fail loudly, not silently report zero.
            MockURLProtocol.reset(with: [.json(#"{"content":[],"stop_reason":"end_turn"}"#)])
            await #expect(throws: (any Error).self) {
                try await makeModel().respond(to: ModelRequest(content: "Hi"))
            }
        }

        @Test func transportFailurePropagates() async {
            MockURLProtocol.reset(with: [
                .init(error: URLError(.notConnectedToInternet))
            ])
            await #expect(throws: (any Error).self) {
                try await makeModel().respond(to: ModelRequest(content: "Hi"))
            }
        }

        // MARK: Tool loop

        @Test func runsToolAndFeedsResultBack() async throws {
            let toolUse = """
            {"content":[{"type":"tool_use","id":"tu_1","name":"echo","input":{"text":"hi"}}],
             "stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}
            """
            MockURLProtocol.reset(with: [.json(toolUse), .json(Self.textResponse)])

            let response = try await makeModel(tools: [EchoNetworkTool()])
                .respond(to: ModelRequest(content: "echo hi"))

            #expect(response.content == "Hello there")
            #expect(MockURLProtocol.requests.count == 2, "should take a second turn")

            // Usage accumulates across turns rather than reporting only the last.
            #expect(response.usage.inputTokens == 22)
            #expect(response.usage.outputTokens == 9)

            let second = try #require(MockURLProtocol.requestBodies().last)
            let json = try JSONSerialization.jsonObject(with: second) as? [String: Any]
            let messages = try #require(json?["messages"] as? [[String: Any]])
            #expect(messages.count == 3, "user, assistant tool_use, tool_result")

            let results = try #require(messages.last?["content"] as? [[String: Any]])
            #expect(results.first?["type"] as? String == "tool_result")
            #expect(results.first?["tool_use_id"] as? String == "tu_1")
            #expect(results.first?["content"] as? String == "HI")
        }

        @Test func toolFailureIsReportedToModelNotThrown() async throws {
            // Missing `text`, so the tool throws. The turn should continue with an
            // error result rather than abandoning the request.
            let toolUse = """
            {"content":[{"type":"tool_use","id":"tu_1","name":"echo","input":{}}],
             "stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}
            """
            MockURLProtocol.reset(with: [.json(toolUse), .json(Self.textResponse)])

            let response = try await makeModel(tools: [EchoNetworkTool()])
                .respond(to: ModelRequest(content: "echo"))
            #expect(response.content == "Hello there")

            let second = try #require(MockURLProtocol.requestBodies().last)
            let json = try JSONSerialization.jsonObject(with: second) as? [String: Any]
            let messages = try #require(json?["messages"] as? [[String: Any]])
            let results = try #require(messages.last?["content"] as? [[String: Any]])
            #expect(results.first?["is_error"] as? Bool == true)
            #expect((results.first?["content"] as? String)?.contains("Error") == true)
        }

        @Test func unknownToolIsReportedNotCrashed() async throws {
            let toolUse = """
            {"content":[{"type":"tool_use","id":"tu_1","name":"nope","input":{}}],
             "stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}
            """
            MockURLProtocol.reset(with: [.json(toolUse), .json(Self.textResponse)])

            let response = try await makeModel(tools: [EchoNetworkTool()])
                .respond(to: ModelRequest(content: "x"))
            #expect(response.content == "Hello there")

            let second = try #require(MockURLProtocol.requestBodies().last)
            let json = try JSONSerialization.jsonObject(with: second) as? [String: Any]
            let messages = try #require(json?["messages"] as? [[String: Any]])
            let results = try #require(messages.last?["content"] as? [[String: Any]])
            #expect(results.first?["is_error"] as? Bool == true)
        }

        @Test func runawayToolLoopIsCapped() async {
            // Always asks for a tool, never settles.
            let toolUse = """
            {"content":[{"type":"tool_use","id":"tu_1","name":"echo","input":{"text":"x"}}],
             "stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}
            """
            MockURLProtocol.reset(with: [.json(toolUse)])

            await #expect(throws: LanguageModelError.toolLoopLimitExceeded(
                turns: AnthropicLanguageModel.maxToolTurns
            )) {
                try await makeModel(tools: [EchoNetworkTool()]).respond(to: ModelRequest(content: "loop"))
            }
            #expect(MockURLProtocol.requests.count == AnthropicLanguageModel.maxToolTurns)
        }

        @Test func toolCallsAreIgnoredWhenNoToolsRegistered() async throws {
            // A tool_use block with an empty registry must not loop forever.
            let toolUse = """
            {"content":[{"type":"text","text":"partial"},
                        {"type":"tool_use","id":"tu_1","name":"echo","input":{}}],
             "stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}
            """
            MockURLProtocol.reset(with: [.json(toolUse)])
            let response = try await makeModel().respond(to: ModelRequest(content: "x"))
            #expect(response.content == "partial")
            #expect(MockURLProtocol.requests.count == 1)
        }

        // MARK: Streaming

        @Test func streamsDeltasAndStopsAtTerminator() async throws {
            MockURLProtocol.reset(with: [.sse([
                #"{"delta":{"text":"Hel"}}"#,
                #"{"delta":{"text":"lo"}}"#,
                "[DONE]",
                #"{"delta":{"text":"IGNORED"}}"#,
            ])])

            var chunks: [String] = []
            for try await chunk in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {
                chunks.append(chunk)
            }
            #expect(chunks == ["Hel", "lo"])
        }

        @Test func streamSetsStreamFlagOnRequest() async throws {
            MockURLProtocol.reset(with: [.sse(["[DONE]"])])
            for try await _ in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {}

            let body = try #require(MockURLProtocol.requestBodies().first)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["stream"] as? Bool == true)
        }

        @Test func streamSkipsUnparseableEventsRatherThanFailing() async throws {
            MockURLProtocol.reset(with: [.sse([
                "{ not json",
                #"{"delta":{}}"#,
                #"{"type":"ping"}"#,
                #"{"delta":{"text":"ok"}}"#,
            ])])

            var chunks: [String] = []
            for try await chunk in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {
                chunks.append(chunk)
            }
            #expect(chunks == ["ok"], "a malformed event should not kill the stream")
        }

        @Test func streamSurfacesHTTPErrors() async {
            MockURLProtocol.reset(with: [.json("nope", status: 500)])
            await #expect(throws: LanguageModelError.unavailable) {
                for try await _ in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {}
            }
        }
    }

    // MARK: - OpenAI

    @Suite("OpenAI backend", .serialized)
    struct OpenAIBackendTests {

        private func makeModel() -> OpenAILanguageModel {
            OpenAILanguageModel(
                config: OpenAIConfiguration(apiKey: "sk-test", model: "gpt-4o"),
                session: MockURLProtocol.makeSession()
            )
        }

        private static let response = """
        {"choices":[{"message":{"content":"Hi back"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":7,"completion_tokens":3}}
        """

        @Test func sendsBearerAuthAndBody() async throws {
            MockURLProtocol.reset(with: [.json(Self.response)])
            _ = try await makeModel().respond(to: ModelRequest(content: "Hello"))

            let request = try #require(MockURLProtocol.requests.first)
            #expect(request.url?.path == "/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

            let body = try #require(MockURLProtocol.requestBodies().first)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["model"] as? String == "gpt-4o")
            #expect(json?["max_completion_tokens"] as? Int == 1024)
        }

        @Test func decodesChoiceAndUsage() async throws {
            MockURLProtocol.reset(with: [.json(Self.response)])
            let response = try await makeModel().respond(to: ModelRequest(content: "Hello"))
            #expect(response.content == "Hi back")
            #expect(response.stopReason == "stop")
            #expect(response.usage.inputTokens == 7)
            #expect(response.usage.outputTokens == 3)
        }

        @Test func emptyChoicesIsAnError() async {
            MockURLProtocol.reset(with: [.json(#"{"choices":[]}"#)])
            await #expect(throws: (any Error).self) {
                try await makeModel().respond(to: ModelRequest(content: "Hello"))
            }
        }

        @Test func nullContentDecodesAsEmpty() async throws {
            MockURLProtocol.reset(with: [.json("""
            {"choices":[{"message":{"content":null},"finish_reason":"stop"}]}
            """)])
            let response = try await makeModel().respond(to: ModelRequest(content: "Hello"))
            #expect(response.content.isEmpty)
            #expect(response.usage.inputTokens == 0, "absent usage defaults to zero")
        }

        @Test func rateLimitIsRetryable() async {
            MockURLProtocol.reset(with: [.json("{}", status: 429)])
            await #expect(throws: LanguageModelError.unavailable) {
                try await makeModel().respond(to: ModelRequest(content: "Hello"))
            }
        }

        @Test func unauthorizedSurfacesDetail() async throws {
            MockURLProtocol.reset(with: [.json(#"{"error":"bad key"}"#, status: 401)])
            do {
                _ = try await makeModel().respond(to: ModelRequest(content: "Hello"))
                Issue.record("expected an error")
            } catch let error as OpenAIError {
                guard case .apiError(let status, _) = error else {
                    Issue.record("wrong case"); return
                }
                #expect(status == 401)
            }
        }

        @Test func streamsDeltaContent() async throws {
            MockURLProtocol.reset(with: [.sse([
                #"{"choices":[{"delta":{"content":"a"}}]}"#,
                #"{"choices":[{"delta":{"content":"b"}}]}"#,
                "[DONE]",
            ])])

            var chunks: [String] = []
            for try await chunk in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {
                chunks.append(chunk)
            }
            #expect(chunks == ["a", "b"])
        }

        @Test func streamIgnoresRoleOnlyDeltas() async throws {
            MockURLProtocol.reset(with: [.sse([
                #"{"choices":[{"delta":{}}]}"#,
                #"{"choices":[{"delta":{"content":"x"}}]}"#,
                "[DONE]",
            ])])

            var chunks: [String] = []
            for try await chunk in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {
                chunks.append(chunk)
            }
            #expect(chunks == ["x"])
        }
    }

    // MARK: - Gemini

    @Suite("Gemini backend", .serialized)
    struct GeminiBackendTests {

        private func makeModel() -> GeminiLanguageModel {
            GeminiLanguageModel(
                config: GeminiConfiguration(apiKey: "AIza-test", model: "gemini-2.0-flash"),
                session: MockURLProtocol.makeSession()
            )
        }

        private static let response = """
        {"candidates":[{"content":{"parts":[{"text":"Hei"}]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}
        """

        @Test func putsKeyInQueryAndUsesGenerateContent() async throws {
            MockURLProtocol.reset(with: [.json(Self.response)])
            _ = try await makeModel().respond(to: ModelRequest(content: "Hello"))

            let request = try #require(MockURLProtocol.requests.first)
            let url = try #require(request.url)
            #expect(url.path.contains("models/gemini-2.0-flash:generateContent"))

            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first(where: { $0.name == "key" })?.value == "AIza-test")
        }

        @Test func streamRequestAsksForSSE() async throws {
            MockURLProtocol.reset(with: [.sse([])])
            for try await _ in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {}

            let url = try #require(MockURLProtocol.requests.first?.url)
            #expect(url.path.contains(":streamGenerateContent"))
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first(where: { $0.name == "alt" })?.value == "sse")
        }

        @Test func decodesCandidateAndUsage() async throws {
            MockURLProtocol.reset(with: [.json(Self.response)])
            let response = try await makeModel().respond(to: ModelRequest(content: "Hello"))
            #expect(response.content == "Hei")
            #expect(response.stopReason == "STOP")
            #expect(response.usage.inputTokens == 5)
            #expect(response.usage.outputTokens == 2)
        }

        @Test func joinsMultipleParts() async throws {
            MockURLProtocol.reset(with: [.json("""
            {"candidates":[{"content":{"parts":[{"text":"a"},{"text":"b"}]}}]}
            """)])
            let response = try await makeModel().respond(to: ModelRequest(content: "Hello"))
            #expect(response.content == "ab")
        }

        @Test func blockedResponseWithNoCandidatesIsAnError() async {
            // Gemini returns 200 with no candidates when safety filters trip.
            MockURLProtocol.reset(with: [.json(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#)])
            await #expect(throws: (any Error).self) {
                try await makeModel().respond(to: ModelRequest(content: "Hello"))
            }
        }

        @Test func serverErrorIsRetryable() async {
            MockURLProtocol.reset(with: [.json("{}", status: 503)])
            await #expect(throws: LanguageModelError.unavailable) {
                try await makeModel().respond(to: ModelRequest(content: "Hello"))
            }
        }

        @Test func streamsPartText() async throws {
            MockURLProtocol.reset(with: [.sse([
                #"{"candidates":[{"content":{"parts":[{"text":"one "}]}}]}"#,
                #"{"candidates":[{"content":{"parts":[{"text":"two"}]}}]}"#,
            ])])

            var chunks: [String] = []
            for try await chunk in makeModel().streamResponse(to: ModelRequest(content: "Hi")) {
                chunks.append(chunk)
            }
            #expect(chunks == ["one ", "two"])
        }
    }

    // MARK: - Token counting

    @Suite("Anthropic token counter", .serialized)
    struct AnthropicTokenCounterTests {

        private func makeCounter() -> AnthropicTokenCounter {
            AnthropicTokenCounter(
                config: AnthropicConfiguration(apiKey: "sk-ant-test"),
                session: MockURLProtocol.makeSession()
            )
        }

        @Test func returnsExactCount() async throws {
            MockURLProtocol.reset(with: [.json(#"{"input_tokens":1234}"#)])
            #expect(try await makeCounter().exactTokenCount(of: "some text") == 1234)

            let request = try #require(MockURLProtocol.requests.first)
            #expect(request.url?.path == "/v1/messages/count_tokens")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        }

        @Test func httpFailureThrowsUnavailable() async {
            MockURLProtocol.reset(with: [.json("{}", status: 500)])
            await #expect(throws: LanguageModelError.unavailable) {
                try await makeCounter().exactTokenCount(of: "x")
            }
        }

        @Test func malformedBodyThrows() async {
            MockURLProtocol.reset(with: [.json(#"{"unexpected":true}"#)])
            await #expect(throws: (any Error).self) {
                try await makeCounter().exactTokenCount(of: "x")
            }
        }
    }

    // MARK: - Retry over a real backend

    @Suite("Retry integration", .serialized)
    struct RetryIntegrationTests {

        @Test func retriesRateLimitThenSucceeds() async throws {
            MockURLProtocol.reset(with: [
                .json("{}", status: 429),
                .json("{}", status: 429),
                .json("""
                {"content":[{"type":"text","text":"finally"}],
                 "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
                """),
            ])

            let model = AnthropicLanguageModel(
                config: AnthropicConfiguration(apiKey: "k"),
                session: MockURLProtocol.makeSession()
            )
            let retrying = RetryingLanguageModel(
                wrapped: model,
                policy: RetryPolicy(maxAttempts: 3, initialDelay: 0, backoffMultiplier: 1, maxDelay: 0)
            )

            let response = try await retrying.respond(to: ModelRequest(content: "Hi"))
            #expect(response.content == "finally")
            #expect(MockURLProtocol.requests.count == 3)
        }

        @Test func doesNotRetryClientErrors() async {
            MockURLProtocol.reset(with: [.json(#"{"error":"bad"}"#, status: 400)])

            let model = AnthropicLanguageModel(
                config: AnthropicConfiguration(apiKey: "k"),
                session: MockURLProtocol.makeSession()
            )
            let retrying = RetryingLanguageModel(
                wrapped: model,
                policy: RetryPolicy(maxAttempts: 3, initialDelay: 0, backoffMultiplier: 1, maxDelay: 0)
            )

            await #expect(throws: (any Error).self) {
                try await retrying.respond(to: ModelRequest(content: "Hi"))
            }
            #expect(MockURLProtocol.requests.count == 1, "a 400 must not be retried")
        }
    }

    // MARK: - Cancellation

    @Suite("Stream cancellation", .serialized)
    struct CancellationTests {

        /// Breaking out of the loop must tear the request down rather than
        /// leaving it draining in the background.
        @Test func anthropicStreamStopsWhenConsumerBreaks() async throws {
            MockURLProtocol.reset(with: [.sse((0..<50).map { #"{"delta":{"text":"\#($0)"}}"# })])

            let model = AnthropicLanguageModel(
                config: AnthropicConfiguration(apiKey: "k"),
                session: MockURLProtocol.makeSession()
            )

            var seen = 0
            for try await _ in model.streamResponse(to: ModelRequest(content: "Hi")) {
                seen += 1
                if seen == 3 { break }
            }
            #expect(seen == 3)
        }

        @Test func openAIStreamStopsWhenConsumerBreaks() async throws {
            MockURLProtocol.reset(with: [.sse(
                (0..<50).map { #"{"choices":[{"delta":{"content":"\#($0)"}}]}"# }
            )])

            let model = OpenAILanguageModel(
                config: OpenAIConfiguration(apiKey: "k"),
                session: MockURLProtocol.makeSession()
            )

            var seen = 0
            for try await _ in model.streamResponse(to: ModelRequest(content: "Hi")) {
                seen += 1
                if seen == 2 { break }
            }
            #expect(seen == 2)
        }

        /// A cancelled parent task must stop the stream too.
        @Test func cancelledTaskEndsStream() async throws {
            MockURLProtocol.reset(with: [.sse((0..<200).map { #"{"delta":{"text":"\#($0)"}}"# })])

            let model = AnthropicLanguageModel(
                config: AnthropicConfiguration(apiKey: "k"),
                session: MockURLProtocol.makeSession()
            )

            let task = Task {
                var count = 0
                for try await _ in model.streamResponse(to: ModelRequest(content: "Hi")) {
                    count += 1
                }
                return count
            }
            task.cancel()
            _ = try? await task.value
        }
    }
}


// MARK: - Fixtures

private struct EchoNetworkTool: ModelTool {
    let name = "echo"
    let description = "Uppercases text."
    let parameterSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
    ])

    func call(arguments: JSONValue) async throws -> String {
        guard let text = arguments["text"]?.stringValue else {
            throw ToolError.invalidArguments("text is required")
        }
        return text.uppercased()
    }
}
