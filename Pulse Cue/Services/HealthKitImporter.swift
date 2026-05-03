//
//  HealthKitImporter.swift
//  Pulse Cue
//
//  Foundation for the future HealthKit integration. Intentionally does
//  NOT link the HealthKit framework or modify the app's entitlements,
//  so the app keeps working with no permission prompts and no code-
//  signing changes. Once HealthKit is enabled in the target capability
//  list and an Info.plist usage description is added, swap
//  `NoopHealthKitImporter` for a real `HKHealthStore`-backed
//  implementation that conforms to `HealthKitImporting`.
//
//  Hard rules for this layer:
//  - DayLog stays the local source of truth.
//  - Nothing imported from HealthKit is written back to DayLog without
//    explicit user confirmation in the UI.
//  - The app must continue to function if `isAvailable == false` or if
//    the user denies permission.
//

import Foundation

/// What kind of metric we are asking HealthKit for.
enum HealthKitMetric: String, CaseIterable, Identifiable {
    case weight
    case sleep
    case activeEnergy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weight: return "体重"
        case .sleep: return "睡眠"
        case .activeEnergy: return "運動消費カロリー"
        }
    }
}

/// Authorization state from the importer's point of view.
enum HealthKitAuthorizationState: Equatable {
    /// Device or build does not support HealthKit at all.
    case unavailable
    /// Supported, but the user has not been asked yet.
    case notDetermined
    /// Supported, the user denied at least one read.
    case denied
    /// Supported, the user authorized read access.
    case authorized
}

/// Single day's worth of imported values, keyed to local date.
struct HealthKitDailySample: Equatable {
    let date: Date
    var weightKg: Double?
    var sleepMinutes: Int?
    var activeEnergyKcal: Int?
}

enum HealthKitImportError: Error, Equatable {
    case unavailable
    case unauthorized
    case backendNotImplemented
}

/// Abstraction every HealthKit-flavored importer must satisfy. The
/// real implementation will live behind a `#if canImport(HealthKit)`
/// guard once the capability is enabled.
protocol HealthKitImporting {
    var isAvailable: Bool { get }
    func currentAuthorizationState() async -> HealthKitAuthorizationState

    /// Ask the user for read access to the requested metrics. The
    /// implementation must be safe to call when the framework is not
    /// linked: it should simply resolve to `.unavailable` in that
    /// case.
    func requestAuthorization(for metrics: Set<HealthKitMetric>) async throws -> HealthKitAuthorizationState

    /// Pull samples for the given local-date range. Implementations
    /// MUST NOT write anything back to DayLog — the caller is
    /// responsible for confirming each sample with the user before
    /// persisting.
    func fetchSamples(
        metrics: Set<HealthKitMetric>,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HealthKitDailySample]
}

/// Default no-op importer. The app uses this until the HealthKit
/// capability is wired up. Returning `.unavailable` keeps the rest of
/// the app on its purely-local code path.
struct NoopHealthKitImporter: HealthKitImporting {
    var isAvailable: Bool { false }

    func currentAuthorizationState() async -> HealthKitAuthorizationState {
        .unavailable
    }

    func requestAuthorization(for metrics: Set<HealthKitMetric>) async throws -> HealthKitAuthorizationState {
        .unavailable
    }

    func fetchSamples(
        metrics: Set<HealthKitMetric>,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HealthKitDailySample] {
        throw HealthKitImportError.unavailable
    }
}

/// Static accessor for the rest of the app. Replace the inner value
/// with a real importer when the capability is enabled.
enum HealthKitImporterProvider {
    /// Returns the current importer. The default is a no-op so the
    /// production app keeps the local-only behaviour described in P0.
    static var shared: HealthKitImporting = NoopHealthKitImporter()
}
