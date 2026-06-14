//
//  APIHealthQAModel.swift
//  Pulse Cue
//
//  DEBUG-only model for the manual API health QA tool. The ENTIRE file is
//  compiled out of Release (`#if DEBUG`), so none of its types or strings can
//  reach a shipping build.
//
//  It builds on the existing `APIIntegrationFoundation` / `APIHealthService`
//  (PR #122/#123): an explicitly-typed, in-memory base URL is turned into a
//  `.custom` configuration → `APIClientFactory` → `APIHealthService`, and a
//  read-only health check is run ONLY when the caller asks. Nothing is
//  persisted (no UserDefaults / Keychain), no token is involved, and no user
//  data is sent (the probe is a body-less GET).
//

#if DEBUG
import Foundation

/// Display result for the DEBUG API health QA tool.
enum APIHealthQAResult: Equatable {
    /// The in-memory base URL is empty / not a valid absolute URL.
    case notConfigured
    case healthy(version: String?)
    case degraded(version: String?)
    /// The client refused to network (e.g. a disabled environment).
    case disabled
    /// A transport / decode / server failure, with a short display message.
    case failed(String)
}

/// Pure, testable helpers behind the DEBUG API health QA view. `@MainActor`
/// because the foundation types are main-actor isolated (app target uses
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
@MainActor
enum APIHealthQAModel {

    /// Builds an `APIHealthService` for an explicit, in-memory base URL string.
    /// Returns `nil` (→ `.notConfigured`) when the string is empty or not a
    /// valid absolute URL, so an empty/invalid field never networks. There is
    /// no default / production URL: the URL comes only from the caller.
    static func makeService(baseURLString: String) -> APIHealthService? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil,
              url.host != nil else {
            return nil
        }
        // Explicit `.custom` environment with the injected URL; no token.
        let configuration = APIConfiguration(environment: .custom(baseURL: url))
        let client = APIClientFactory.makeClient(for: configuration)
        return APIHealthService(client: client)
    }

    /// Runs a read-only health check against an already-built service and maps
    /// the outcome to a display result. Injectable so tests can supply a
    /// mock-backed service and never perform real networking.
    static func check(using service: APIHealthService) async -> APIHealthQAResult {
        do {
            let status = try await service.checkHealth()
            return status.isHealthy
                ? .healthy(version: status.version)
                : .degraded(version: status.version)
        } catch let error as APIServiceError {
            if error == .disabled { return .disabled }
            return .failed(message(for: error))
        } catch {
            return .failed("不明なエラー")
        }
    }

    /// Convenience: validate the in-memory base URL string and run the check.
    /// Empty / invalid input short-circuits to `.notConfigured` without
    /// constructing a client or touching the network.
    static func check(baseURLString: String) async -> APIHealthQAResult {
        guard let service = makeService(baseURLString: baseURLString) else {
            return .notConfigured
        }
        return await check(using: service)
    }

    /// Short, display-only message for a service error. No raw bodies or
    /// provider internals are surfaced.
    static func message(for error: APIServiceError) -> String {
        switch error {
        case .disabled:           return "通信は無効です"
        case .decodingFailed:     return "レスポンスを解釈できませんでした"
        case .unauthorized:       return "認証エラー (401)"
        case let .server(code):   return "サーバーエラー (\(code.rawValue))"
        case .transport:          return "接続に失敗しました"
        case .unknown:            return "不明なエラー"
        }
    }
}
#endif
