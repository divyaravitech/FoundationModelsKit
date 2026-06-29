// RegionalAvailability.swift
// Tracks which model backends are reachable from a given deployment region,
// and selects the best available tier for a request.

// MARK: - Region

/// A coarse geographic region used to gate backend availability.
///
/// The `.global` case is used when no region-specific record exists or when
/// running in a context where region cannot be determined (e.g. on-device
/// with no network, simulator, unit tests).
public enum Region: String, Sendable, Codable, CaseIterable {
    case usEast   = "us-east"
    case usWest   = "us-west"
    case eu       = "eu"
    case apac     = "apac"
    case global   = "global"
}

// MARK: - ModelAvailability

/// Snapshot of which backends are accessible and how fast they respond in
/// a particular region.
public struct ModelAvailability: Sendable, Codable {
    /// The region this record applies to.
    public var region: Region

    /// Whether the on-device model can be loaded (always `true` when hardware
    /// supports it, regardless of region).
    public var onDeviceAvailable: Bool

    /// Whether Apple Private Cloud Compute is reachable from this region.
    public var pccAvailable: Bool

    /// Whether the configured third-party API is reachable from this region.
    public var thirdPartyAvailable: Bool

    /// Round-trip latency to the best available remote backend, in milliseconds.
    /// `nil` when only the on-device model is accessible.
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
    /// On-device is universally available; remote backends use conservative defaults.
    public static let defaults: [Region: ModelAvailability] = [
        .global:  ModelAvailability(region: .global,  onDeviceAvailable: true, pccAvailable: false, thirdPartyAvailable: true,  latency: 300),
        .usEast:  ModelAvailability(region: .usEast,  onDeviceAvailable: true, pccAvailable: true,  thirdPartyAvailable: true,  latency: 60),
        .usWest:  ModelAvailability(region: .usWest,  onDeviceAvailable: true, pccAvailable: true,  thirdPartyAvailable: true,  latency: 80),
        .eu:      ModelAvailability(region: .eu,      onDeviceAvailable: true, pccAvailable: true,  thirdPartyAvailable: false, latency: 120),
        .apac:    ModelAvailability(region: .apac,    onDeviceAvailable: true, pccAvailable: false, thirdPartyAvailable: true,  latency: 200),
    ]
}

// MARK: - RegionalAvailability

/// Actor-isolated registry of per-region backend availability.
///
/// Usage:
/// ```swift
/// let registry = RegionalAvailability()
/// let region = await registry.currentRegion()
/// let tier = await registry.bestTierFor(region: region)  // e.g. .pcc
/// ```
public actor RegionalAvailability: Sendable {

    // Keyed by region for O(1) lookup and O(1) updates.
    private var availabilities: [Region: ModelAvailability]

    /// Initialise with an explicit set of availability records.
    /// Any region not covered falls back to the `.global` entry at query time.
    public init(availabilities: [ModelAvailability] = Array(ModelAvailability.defaults.values)) {
        self.availabilities = Dictionary(
            uniqueKeysWithValues: availabilities.map { ($0.region, $0) }
        )
    }

    // MARK: - Queries

    /// Returns the availability record for `region`, or `nil` if none is
    /// registered (and no `.global` fallback exists).
    public func availability(for region: Region) -> ModelAvailability? {
        availabilities[region] ?? availabilities[.global]
    }

    /// Returns the highest-capability tier available in `region`.
    ///
    /// Priority: on-device > PCC > third-party.
    /// Returns `nil` when no backend is available at all.
    public func bestTierFor(region: Region) -> ModelTier? {
        guard let record = availability(for: region) else { return nil }

        // On-device is always preferred — no latency, no data leaves the device.
        if record.onDeviceAvailable { return .onDevice }
        if record.pccAvailable      { return .pcc }
        if record.thirdPartyAvailable { return .thirdParty }
        return nil
    }

    /// Returns the region the current process is considered to be running in.
    ///
    /// This implementation returns `.global` as a safe placeholder.
    /// In production, replace with a network-based region lookup or a value
    /// injected from the host application's configuration.
    public func currentRegion() -> Region {
        .global
    }

    // MARK: - Mutations

    /// Inserts or replaces the availability record for a region.
    /// Useful for dynamic updates pushed from a configuration service.
    public func updateAvailability(_ availability: ModelAvailability) {
        availabilities[availability.region] = availability
    }
}
