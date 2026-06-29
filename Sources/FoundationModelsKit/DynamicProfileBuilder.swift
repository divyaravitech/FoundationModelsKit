// DynamicProfileBuilder.swift
// Defines routing profiles and a fluent builder for creating them.
//
// A DynamicProfile tells the system how to route requests and manage
// context windows for a given use-case (on-device only, cloud-first, etc.).

// MARK: - RoutingStrategy

/// Describes how the router should prioritise available backends.
public enum RoutingStrategy: String, Sendable, Codable, CaseIterable {
    /// Always prefer the on-device model; never escalate.
    case preferOnDevice
    /// Prefer Private Cloud Compute; fall back to on-device.
    case preferPCC
    /// Prefer a third-party API; fall back to PCC then on-device.
    case preferThirdParty
    /// Let the router decide based on request size, complexity, and privacy.
    case adaptive
}

// MARK: - DynamicProfile

/// A value-type snapshot of routing and context-management preferences.
public struct DynamicProfile: Sendable, Codable {
    /// Human-readable identifier for this profile.
    public var name: String

    /// How the router should pick a backend for each request.
    public var routingStrategy: RoutingStrategy

    /// Maximum number of tokens allowed in the conversation context before
    /// `ConversationStore` is asked to compact.
    public var maxContextTokens: Int

    /// When `true`, `ConversationStore.compact()` is called automatically
    /// whenever `shouldCompact(maxTokens:)` returns `true`.
    public var autoCompact: Bool

    /// Default privacy level applied to every request routed under this profile.
    public var privacySensitivity: PrivacySensitivity

    public init(
        name: String,
        routingStrategy: RoutingStrategy,
        maxContextTokens: Int,
        autoCompact: Bool,
        privacySensitivity: PrivacySensitivity
    ) {
        self.name = name
        self.routingStrategy = routingStrategy
        self.maxContextTokens = maxContextTokens
        self.autoCompact = autoCompact
        self.privacySensitivity = privacySensitivity
    }
}

// MARK: - Pre-built profiles

extension DynamicProfile {
    /// Restricts all inference to the on-device model.
    /// No data ever leaves the device. Suitable for the most sensitive workloads.
    public static let onDeviceOnly = DynamicProfile(
        name: "onDeviceOnly",
        routingStrategy: .preferOnDevice,
        maxContextTokens: 2048,
        autoCompact: true,
        privacySensitivity: .high
    )

    /// Tries the on-device model first and falls back to PCC for larger tasks.
    /// Good default for most privacy-conscious applications.
    public static let balanced = DynamicProfile(
        name: "balanced",
        routingStrategy: .adaptive,
        maxContextTokens: 4096,
        autoCompact: true,
        privacySensitivity: .medium
    )

    /// Routes to PCC (or a third-party API) first for maximum capability,
    /// falling back to on-device only when cloud backends are unavailable.
    public static let cloudFirst = DynamicProfile(
        name: "cloudFirst",
        routingStrategy: .preferPCC,
        maxContextTokens: 8192,
        autoCompact: true,
        privacySensitivity: .low
    )
}

// MARK: - Builder

/// Fluent builder for `DynamicProfile`.
///
/// Usage:
/// ```swift
/// let profile = DynamicProfileBuilder()
///     .withName("myApp")
///     .withRoutingStrategy(.preferOnDevice)
///     .withMaxContextTokens(2048)
///     .withAutoCompact(false)
///     .withPrivacySensitivity(.high)
///     .build()
/// ```
public struct DynamicProfileBuilder: Sendable {
    private var name: String = "default"
    private var routingStrategy: RoutingStrategy = .adaptive
    private var maxContextTokens: Int = 4096
    private var autoCompact: Bool = true
    private var privacySensitivity: PrivacySensitivity = .medium

    public init() {}

    public func withName(_ name: String) -> DynamicProfileBuilder {
        var copy = self; copy.name = name; return copy
    }

    public func withRoutingStrategy(_ strategy: RoutingStrategy) -> DynamicProfileBuilder {
        var copy = self; copy.routingStrategy = strategy; return copy
    }

    public func withMaxContextTokens(_ tokens: Int) -> DynamicProfileBuilder {
        var copy = self; copy.maxContextTokens = tokens; return copy
    }

    public func withAutoCompact(_ enabled: Bool) -> DynamicProfileBuilder {
        var copy = self; copy.autoCompact = enabled; return copy
    }

    public func withPrivacySensitivity(_ sensitivity: PrivacySensitivity) -> DynamicProfileBuilder {
        var copy = self; copy.privacySensitivity = sensitivity; return copy
    }

    /// Finalises the builder and returns an immutable `DynamicProfile`.
    public func build() -> DynamicProfile {
        DynamicProfile(
            name: name,
            routingStrategy: routingStrategy,
            maxContextTokens: maxContextTokens,
            autoCompact: autoCompact,
            privacySensitivity: privacySensitivity
        )
    }
}
