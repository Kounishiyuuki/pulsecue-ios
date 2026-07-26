//
//  AccentContractGuardTests.swift
//  Pulse CueTests
//
//  Call-site guard for the filled-accent colour contract.
//
//  `AppThemeContrastTests` proves the *token* `AppTheme.accentFilled` is
//  contrast-safe. This test guards the other half of the contract: developers
//  must not put white foreground on the plain, tint-tuned `AppTheme.accent`
//  as a solid filled surface (that combination fails AA in dark mode). Such
//  surfaces must use `AppTheme.accentFilled`.
//
//  What it proves: no app SwiftUI source places a white foreground within a
//  few lines of a *solid* `fill(AppTheme.accent)` / `background(AppTheme.accent)`.
//  What it does NOT prove: semantic correctness of every accent use, patterns
//  split across many lines or behind helper indirection, or the separate
//  legacy `MyGymStyle.accentGradient` token. It is a proximity heuristic over
//  source text — deliberately simple, no parser/lint dependency — sized to
//  catch this specific, recurring mistake class.
//
//  Requires the repository source tree to be present (it reads `.swift`
//  files next to the test target); it is skipped gracefully if not found.
//

import Foundation
import Testing

struct AccentContractGuardTests {

    /// Solid plain-accent fill: `fill(AppTheme.accent)` / `background(AppTheme.accent)`
    /// where `accent` is immediately closed by `)` — i.e. NOT `accentFilled`,
    /// `accentSoft`, or `accent.opacity(...)`.
    private static let solidAccentFill = try! NSRegularExpression(
        pattern: #"(?:fill|background)\(AppTheme\.accent\)"#
    )

    /// Opaque white foreground: `.white` closed by `)` — NOT `.white.opacity(...)`.
    private static let whiteForeground = try! NSRegularExpression(
        pattern: #"foreground(?:Style|Color)\(\s*(?:Color\.)?\.?white\s*\)"#
    )

    /// Proximity window (lines) within which a white foreground and a solid
    /// accent fill are treated as belonging to the same UI element.
    private static let window = 6

    private func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }

    /// Locates the app source directory ("Pulse Cue") from this test's path.
    private func appSourceDirectory() -> URL? {
        // #filePath → .../Pulse CueTests/AccentContractGuardTests.swift
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let appDir = repoRoot.appendingPathComponent("Pulse Cue", isDirectory: true)
        return FileManager.default.fileExists(atPath: appDir.path) ? appDir : nil
    }

    private func swiftFiles(under dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func noWhiteForegroundOnSolidPlainAccent() throws {
        guard let appDir = appSourceDirectory() else {
            // Source tree unavailable (e.g. running from an installed bundle
            // without the repo) — nothing to scan, so nothing to assert.
            return
        }

        var violations: [String] = []

        for file in swiftFiles(under: appDir) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)

            let fillLines = lines.indices.filter { matches(Self.solidAccentFill, lines[$0]) }
            guard !fillLines.isEmpty else { continue }
            let whiteLines = lines.indices.filter { matches(Self.whiteForeground, lines[$0]) }
            guard !whiteLines.isEmpty else { continue }

            for f in fillLines {
                if whiteLines.contains(where: { abs($0 - f) <= Self.window }) {
                    violations.append("\(file.lastPathComponent):\(f + 1)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "white-on-solid-AppTheme.accent found (use AppTheme.accentFilled): \(violations)"
        )
    }
}
