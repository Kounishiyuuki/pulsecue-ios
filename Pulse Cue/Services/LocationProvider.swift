//
//  LocationProvider.swift
//  Pulse Cue
//
//  Protocol abstraction around `CLLocationManager` so the nearby gym
//  search ViewModel never imports CoreLocation directly. Keeping it
//  async/await + protocol-driven makes the state-machine tests
//  trivial — every authorization and acquisition outcome is reachable
//  via `FakeLocationProvider` without touching real CoreLocation.
//
//  Permission scope is intentionally `WhenInUse` only. There is no
//  Always usage in this feature and the app does not run location
//  updates in the background.
//

import CoreLocation
import Foundation

@MainActor
protocol LocationProvider {
    /// Current authorization, read synchronously on the main actor.
    /// Reflects the CL instance's view at the time of access; in
    /// production the status changes as the user moves through the
    /// system prompt.
    var authorizationStatus: CLAuthorizationStatus { get }

    /// Requests `WhenInUse` permission if status is `.notDetermined`;
    /// otherwise returns the current status without prompting. Resolves
    /// after the system has settled on a non-notDetermined status.
    func requestPermission() async -> CLAuthorizationStatus

    /// One-shot location fetch. Throws `LocationProviderError` for
    /// every failure surface the UI cares about; never returns a stale
    /// "no location yet" placeholder.
    func currentLocation() async throws -> CLLocation
}

enum LocationProviderError: LocalizedError, Equatable {
    /// App-level permission denied or restricted.
    case unauthorized
    /// CoreLocation reported a fix failure (network down, hardware
    /// problem, simulator with no custom location).
    case unavailable(String)
    /// Coordinate acquisition timed out.
    case timeout
    /// Anything else, with the underlying message for log/UI display.
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "位置情報の利用が許可されていません。"
        case .unavailable(let message):
            return "位置情報を取得できませんでした。(\(message))"
        case .timeout:
            return "位置情報の取得がタイムアウトしました。"
        case .other(let message):
            return "位置情報の取得に失敗しました。(\(message))"
        }
    }
}
