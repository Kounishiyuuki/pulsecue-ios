//
//  FakeLocationProvider.swift
//  Pulse Cue
//
//  Deterministic test/preview `LocationProvider`. The VM tests drive
//  every authorization + location-acquisition branch through this
//  type without touching CoreLocation.
//

import CoreLocation
import Foundation

@MainActor
final class FakeLocationProvider: LocationProvider {
    var initialStatus: CLAuthorizationStatus
    /// Status the fake transitions to after `requestPermission()` is
    /// called when initial status was `.notDetermined`. Defaults to
    /// `.authorizedWhenInUse` (user approved).
    var afterPromptStatus: CLAuthorizationStatus
    var locationResult: Result<CLLocation, Error>

    private(set) var requestPermissionCalls = 0
    private(set) var currentLocationCalls = 0

    init(
        initialStatus: CLAuthorizationStatus = .notDetermined,
        afterPromptStatus: CLAuthorizationStatus = .authorizedWhenInUse,
        locationResult: Result<CLLocation, Error> = .success(
            CLLocation(latitude: 36.5611, longitude: 136.6562) // 金沢駅西
        )
    ) {
        self.initialStatus = initialStatus
        self.afterPromptStatus = afterPromptStatus
        self.locationResult = locationResult
    }

    var authorizationStatus: CLAuthorizationStatus { initialStatus }

    func requestPermission() async -> CLAuthorizationStatus {
        requestPermissionCalls += 1
        if initialStatus == .notDetermined {
            initialStatus = afterPromptStatus
        }
        return initialStatus
    }

    func currentLocation() async throws -> CLLocation {
        currentLocationCalls += 1
        switch locationResult {
        case .success(let location):
            return location
        case .failure(let error):
            throw error
        }
    }
}
