// ModelRouter.swift
// Routes requests to the appropriate language model backend.
//
// Privacy is enforced unconditionally before any heuristic:
//   .high   → on-device only, never escalates
//   .medium → on-device for simple/small requests, PCC otherwise
//   .low    → full fallback chain (on-device → PCC → third-party)

/// Routes requests to the appropriate language model based on privacy, complexity, and content size.
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
    public func sendMessage(request: ModelRequest) async throws -> ModelResponse {
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
            return try await onDeviceModel.sendMessage(request: request)

        case .medium:
            if isOnDeviceEligible(request) {
                return try await onDeviceModel.sendMessage(request: request)
            }
            if let pcc = pccModel {
                return try await pcc.sendMessage(request: request)
            }
            // Fall back to on-device rather than leaking medium-sensitivity data
            // to a third-party endpoint.
            return try await onDeviceModel.sendMessage(request: request)

        case .low:
            if isOnDeviceEligible(request) {
                return try await onDeviceModel.sendMessage(request: request)
            }
            if let pcc = pccModel {
                return try await pcc.sendMessage(request: request)
            }
            if let thirdParty = thirdPartyModel {
                return try await thirdParty.sendMessage(request: request)
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

    // MARK: - Private helpers

    private func isOnDeviceEligible(_ request: ModelRequest) -> Bool {
        let isSmall  = request.content.count < 500
        let hasNoTools = request.tools?.isEmpty != false
        let isSimple = request.taskComplexity == .simple
        return isSmall && hasNoTools && isSimple
    }
}
