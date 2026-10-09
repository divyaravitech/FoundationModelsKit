public actor ModelRouter: LanguageModelProviding {
    private let onDeviceModel: any LanguageModelProviding
    private let pccModel: (any LanguageModelProviding)?
    private let thirdPartyModel: (any LanguageModelProviding)?

    public init(
        onDevice: any LanguageModelProviding,
        pcc: (any LanguageModelProviding)? = nil,
        thirdParty: (any LanguageModelProviding)? = nil
    ) {
        self.onDeviceModel = onDevice
        self.pccModel = pcc
        self.thirdPartyModel = thirdParty
    }

    // MARK: - LanguageModelProviding

    /// Conformance lets `ModelRouter` be passed anywhere a `LanguageModelProviding`
    /// is expected (e.g. `ConversationStore.compact`) without a separate bridge type.
    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        try await routeRequest(request)
    }

    // MARK: - Routing

    /// Selects a backend and forwards the request.
    ///
    /// Privacy is enforced first, then heuristics apply:
    /// - `.high` → on-device only (regardless of size or complexity)
    /// - `.medium` + small + simple → on-device; otherwise PCC
    /// - `.low` → on-device for small/simple; PCC → third-party for everything else
    public func routeRequest(_ request: ModelRequest) async throws -> ModelResponse {
        switch request.privacySensitivity {

        case .high:
            // Data must never leave the device.
            return try await onDeviceModel.respond(to: request)

        case .medium:
            if isOnDeviceEligible(request) {
                return try await onDeviceModel.respond(to: request)
            }
            if let pcc = pccModel {
                return try await pcc.respond(to: request)
            }
            // On-device rather than a third party.
            return try await onDeviceModel.respond(to: request)

        case .low:
            if isOnDeviceEligible(request) {
                return try await onDeviceModel.respond(to: request)
            }
            if let pcc = pccModel {
                return try await pcc.respond(to: request)
            }
            if let thirdParty = thirdPartyModel {
                return try await thirdParty.respond(to: request)
            }
            throw LanguageModelError.unavailable
        }
    }

    /// Derives the tier a given request *would* be sent to, without sending it.
    /// Returns `nil` when no eligible backend exists and the call would throw.
    public func resolvedTier(for request: ModelRequest) -> ModelTier? {
        switch request.privacySensitivity {
        case .high:
            return .onDevice

        case .medium:
            if isOnDeviceEligible(request) { return .onDevice }
            return pccModel != nil ? .pcc : .onDevice

        case .low:
            if isOnDeviceEligible(request) { return .onDevice }
            if pccModel != nil { return .pcc }
            if thirdPartyModel != nil { return .thirdParty }
            return nil
        }
    }

    // MARK: - Eligibility heuristic

    /// Longest prompt, in characters, still considered a good fit for the
    /// on-device model.
    ///
    /// Deliberately conservative: the on-device model is the least capable
    /// tier, so the cost of keeping a borderline prompt local is a weaker
    /// answer, while the cost of escalating one unnecessarily is latency and
    /// a wider data-exposure surface.
    public static let onDeviceCharacterLimit = 500

    /// Whether a request is a good fit for the on-device model, ignoring
    /// privacy — `routeRequest(_:)` applies the privacy rules first.
    ///
    /// A request qualifies when all three hold: it is under
    /// ``onDeviceCharacterLimit`` characters, it is declared
    /// ``TaskComplexity/simple``, and either it needs no tools or the
    /// on-device backend was given the tools it asks for.
    private func isOnDeviceEligible(_ request: ModelRequest) -> Bool {
        let isSmall = request.content.count < Self.onDeviceCharacterLimit
        let toolsSatisfied = request.tools?.isEmpty != false || onDeviceModel.supportsTools
        let isSimple = request.taskComplexity == .simple
        return isSmall && toolsSatisfied && isSimple
    }
}
