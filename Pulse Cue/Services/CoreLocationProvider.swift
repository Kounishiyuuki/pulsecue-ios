//
//  CoreLocationProvider.swift
//  Pulse Cue
//
//  Production `LocationProvider` that wraps `CLLocationManager`. The
//  manager's API is callback-only (`CLLocationManagerDelegate`); this
//  type funnels both the permission flow and the one-shot location
//  fetch into async/await via `CheckedContinuation`s.
//
//  Correctness rule: each continuation is resumed at most once. The
//  delegate callbacks read + clear the corresponding pending slot,
//  guarded by `@MainActor` so there is no cross-thread racing on the
//  optional state. Without this guard, a `didFailWithError` arriving
//  after a `didUpdateLocations` would attempt to resume an already-
//  consumed continuation and trap.
//

import CoreLocation
import Foundation

@MainActor
final class CoreLocationProvider: NSObject, LocationProvider {

    private let manager: CLLocationManager
    private var pendingPermissionContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var pendingLocationContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        self.manager = CLLocationManager()
        super.init()
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func requestPermission() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLAuthorizationStatus, Never>) in
            // If something is already waiting on the permission prompt
            // (which shouldn't normally happen), resume the previous
            // waiter with the current status and replace it.
            pendingPermissionContinuation?.resume(returning: current)
            pendingPermissionContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentLocation() async throws -> CLLocation {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationProviderError.unauthorized
        case .notDetermined:
            throw LocationProviderError.unauthorized
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            throw LocationProviderError.unauthorized
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            if let previous = pendingLocationContinuation {
                previous.resume(throwing: LocationProviderError.other("superseded"))
            }
            pendingLocationContinuation = continuation
            manager.requestLocation()
        }
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let continuation = self.pendingPermissionContinuation {
                self.pendingPermissionContinuation = nil
                continuation.resume(returning: status)
            }
            // If the user revokes permission while a location request
            // is in flight, surface that as an unauthorized error so
            // the VM doesn't hang.
            if status == .denied || status == .restricted,
               let locContinuation = self.pendingLocationContinuation {
                self.pendingLocationContinuation = nil
                locContinuation.resume(throwing: LocationProviderError.unauthorized)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let first = locations.first else { return }
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.pendingLocationContinuation else { return }
            self.pendingLocationContinuation = nil
            continuation.resume(returning: first)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.pendingLocationContinuation else { return }
            self.pendingLocationContinuation = nil
            let mapped: LocationProviderError
            if let clError = error as? CLError {
                switch clError.code {
                case .denied:
                    mapped = .unauthorized
                case .network:
                    mapped = .unavailable("ネットワークに接続できません")
                case .locationUnknown:
                    mapped = .unavailable("位置情報を特定できません")
                default:
                    mapped = .other(clError.localizedDescription)
                }
            } else {
                mapped = .other(error.localizedDescription)
            }
            continuation.resume(throwing: mapped)
        }
    }
}
