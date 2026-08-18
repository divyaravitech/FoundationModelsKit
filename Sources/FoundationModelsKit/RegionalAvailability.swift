// RegionalAvailability.swift
import Foundation
// Tracks which model backends are reachable from a given deployment region
// and selects the best tier for a request given a routing strategy.

// MARK: - Region

/// A coarse geographic region used to gate backend availability.
///
/// `.global` is the safe fallback when region cannot be determined (e.g.
/// simulator, offline, unit tests).
public enum Region: String, Sendable, Codable, CaseIterable, Hashable {
    case usEast = "us-east"
    case usWest = "us-west"
    case eu     = "eu"
    case apac   = "apac"
    case global = "global"
}

// MARK: - ModelAvailability

/// Snapshot of which backends are accessible and how fast they respond in
/// a particular region.
public struct ModelAvailability: Sendable, Codable {
    public var region: Region

    /// On-device inference is available (hardware-dependent, never network-gated).
    public var onDeviceAvailable: Bool

    /// Apple Private Cloud Compute is reachable from this region.
    public var pccAvailable: Bool

    /// The configured third-party API is reachable from this region.
    public var thirdPartyAvailable: Bool

    /// Round-trip latency to the best available *remote* backend in milliseconds.
    /// `nil` when only the on-device model is reachable.
    public var latency: Int?

    public init(
        region: Region,
        onDeviceAvailable: Bool,
        pccAvailable: Bool,
        thirdPartyAvailable: Bool,
        latency: Int? = nil
    ) {
        self.region = region
        self.onDeviceAvailable = onDeviceAvailable
        self.pccAvailable = pccAvailable
        self.thirdPartyAvailable = thirdPartyAvailable
        self.latency = latency
    }
}

// MARK: - Sensible defaults

extension ModelAvailability {
    /// Conservative per-region baseline.
    /// On-device is always `true`; remote backends reflect realistic availability.
    public static let defaults: [Region: ModelAvailability] = [
        .global: ModelAvailability(region: .global, onDeviceAvailable: true, pccAvailable: false, thirdPartyAvailable: true,  latency: 300),
        .usEast: ModelAvailability(region: .usEast, onDeviceAvailable: true, pccAvailable: true,  thirdPartyAvailable: true,  latency: 60),
        .usWest: ModelAvailability(region: .usWest, onDeviceAvailable: true, pccAvailable: true,  thirdPartyAvailable: true,  latency: 80),
        .eu:     ModelAvailability(region: .eu,     onDeviceAvailable: true, pccAvailable: true,  thirdPartyAvailable: false, latency: 120),
        .apac:   ModelAvailability(region: .apac,   onDeviceAvailable: true, pccAvailable: false, thirdPartyAvailable: true,  latency: 200),
    ]
}

// MARK: - RegionalAvailability

/// Actor-isolated registry of per-region backend availability.
///
/// Usage:
/// ```swift
/// let registry = RegionalAvailability()
/// let region   = await registry.currentRegion()
/// let tier     = await registry.bestRemoteTierFor(region: region)  // .pcc or .thirdParty
/// ```
public actor RegionalAvailability: Sendable {

    private var availabilities: [Region: ModelAvailability]

    public init(availabilities: [ModelAvailability] = Array(ModelAvailability.defaults.values)) {
        self.availabilities = Dictionary(
            uniqueKeysWithValues: availabilities.map { ($0.region, $0) }
        )
    }

    // MARK: - Queries

    /// Returns the availability record for `region`, falling back to `.global`.
    public func availability(for region: Region) -> ModelAvailability? {
        availabilities[region] ?? availabilities[.global]
    }

    /// Returns the **best remote tier** available in `region` (PCC > third-party),
    /// or `nil` when no remote backend is reachable.
    ///
    /// On-device is intentionally excluded: it is always available and callers
    /// use this to decide *whether* to escalate beyond on-device, not as a
    /// tiebreaker. Use `availability(for:).onDeviceAvailable` for that check.
    public func bestRemoteTierFor(region: Region) -> ModelTier? {
        guard let record = availability(for: region) else { return nil }
        if record.pccAvailable        { return .pcc }
        if record.thirdPartyAvailable { return .thirdParty }
        return nil
    }

    /// Returns the highest-capability tier available in `region` including on-device.
    ///
    /// Priority: PCC > third-party > on-device (capability order).
    /// Returns `nil` only when the region has zero backends — which should not
    /// happen in practice given on-device is always true.
    public func bestTierFor(region: Region) -> ModelTier? {
        guard let record = availability(for: region) else { return nil }
        if record.pccAvailable        { return .pcc }
        if record.thirdPartyAvailable { return .thirdParty }
        if record.onDeviceAvailable   { return .onDevice }
        return nil
    }

    /// Returns the region inferred from the device's current locale/timezone.
    ///
    /// Mapping is coarse (timezone → region) and is a best-effort guess.
    /// Override by calling `updateAvailability(_:)` with a server-resolved record.
    public func currentRegion() -> Region {
        let tz = TimeZone.current.identifier
        switch true {
        case tz.hasPrefix("America/New_York"), tz.hasPrefix("America/Toronto"),
             tz.hasPrefix("America/Chicago"), tz.hasPrefix("America/Detroit"):
            return .usEast
        case tz.hasPrefix("America/Los_Angeles"), tz.hasPrefix("America/Vancouver"),
             tz.hasPrefix("America/Denver"), tz.hasPrefix("America/Phoenix"):
            return .usWest
        case tz.hasPrefix("Europe/"):
            return .eu
        case tz.hasPrefix("Asia/"), tz.hasPrefix("Australia/"), tz.hasPrefix("Pacific/"):
            return .apac
        default:
            return .global
        }
    }

    // MARK: - Mutations

    /// Inserts or replaces the availability record for a region.
    public func updateAvailability(_ availability: ModelAvailability) {
        availabilities[availability.region] = availability
    }
}
