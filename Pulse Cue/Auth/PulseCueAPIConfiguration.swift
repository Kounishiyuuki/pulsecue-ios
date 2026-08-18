//
//  PulseCueAPIConfiguration.swift
//  Pulse Cue
//
//  Where the PulseCue account API lives — read from Info.plist, never
//  compiled in.
//
//  No production URL exists yet, and none is hardcoded here. Until one is
//  configured the account layer is simply unavailable, and that has a precise
//  meaning:
//
//    * it does NOT connect to some other endpoint
//    * it does NOT quietly fall back to localhost
//    * it does NOT crash
//    * it does NOT break Guest, or any local feature
//
//  Only the account features fail closed. Everything PulseCue does today —
//  Home, My Gym, Quick Plan, Runner, History, Progress, health input — works
//  exactly as before with no server at all, and that has to stay true.
//
//  The URL is validated rather than trusted: HTTPS only, a real host, and no
//  embedded credentials. A misconfigured build should refuse to talk to
//  anything rather than send session tokens somewhere unexpected.
//

import Foundation

struct PulseCueAPIConfiguration: Equatable {

    /// The documented placeholder shipped in Info.plist until a real API
    /// exists. Kept in sync with `Pulse Cue/Info.plist`.
    static let placeholderBaseURL = "https://YOUR_PULSECUE_API_HOST"

    /// The validated base URL, or nil when the account API is not configured.
    let baseURL: URL?

    init(rawValue: String?) {
        self.baseURL = PulseCueAPIConfiguration.validated(rawValue)
    }

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    /// Reads `PulseCueAPIBaseURL` from the main bundle's Info.plist.
    static func fromMainBundle(
        bundle: Bundle = .main
    ) -> PulseCueAPIConfiguration {
        PulseCueAPIConfiguration(
            rawValue: bundle.object(forInfoDictionaryKey: "PulseCueAPIBaseURL") as? String
        )
    }

    /// True only when a usable API endpoint is configured.
    var isConfigured: Bool { baseURL != nil }

    /// Builds a URL for an API path, or nil when unconfigured.
    ///
    /// Paths are fixed string literals at every call site — there is no user
    /// input in a URL here, and none should ever be added without escaping.
    func url(forPath path: String) -> URL? {
        guard let baseURL else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Validation

    private static func validated(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // The shipped placeholder is not a destination.
        guard trimmed != placeholderBaseURL,
              !trimmed.contains("YOUR_PULSECUE_API_HOST")
        else { return nil }

        guard let components = URLComponents(string: trimmed) else { return nil }

        // HTTPS only. A session token must never leave the device in the
        // clear, and there is no development exception here — a local server
        // is reached through a build that configures its own HTTPS URL.
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }

        // Credentials in a URL would end up in logs and proxies.
        guard components.user == nil, components.password == nil else { return nil }

        // A base URL needs a trailing slash or `URL(string:relativeTo:)`
        // drops its last path component when resolving.
        var normalized = components
        if !normalized.path.hasSuffix("/") {
            normalized.path += "/"
        }
        normalized.query = nil
        normalized.fragment = nil
        return normalized.url
    }
}
