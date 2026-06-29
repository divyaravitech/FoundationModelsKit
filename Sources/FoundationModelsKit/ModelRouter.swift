// ModelRouter.swift
// Routes requests to the appropriate language model backend based on
// content size, tool usage, and task complexity.
//
// Fallback chain: on-device → PCC → third-party → throws .unavailable

/// Routes requests to the appropriate language model based on complexity and privacy.
public actor ModelRouter {
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

    /// Selects a backend and forwards the request.
    ///
    /// Routing heuristic:
    /// - Small payload (< 500 chars) + no tools + simple complexity → on-device
    /// - Anything else → PCC if available, then third-party, then throws
    public func routeRequest(_ request: ModelRequest) async throws -> ModelResponse {
        let isSmallRequest = request.content.count < 500
        let hasNoTools = request.tools?.isEmpty != false
        let isSimple = request.taskComplexity == .simple

        if isSmallRequest && hasNoTools && isSimple {
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

    /// Convenience — derives the tier that *would* handle a given request
    /// without actually sending it. Useful for logging and telemetry.
    public func resolvedTier(for request: ModelRequest) -> ModelTier {
        let isSmallRequest = request.content.count < 500
        let hasNoTools = request.tools?.isEmpty != false
        let isSimple = request.taskComplexity == .simple

        if isSmallRequest && hasNoTools && isSimple {
            return .onDevice
        }
        if pccModel != nil { return .pcc }
        if thirdPartyModel != nil { return .thirdParty }
        return .onDevice
    }
}
