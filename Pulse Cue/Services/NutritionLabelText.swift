//
//  NutritionLabelText.swift
//  Pulse Cue
//
//  Pure parser that turns the raw text recognized from a photographed
//  nutrition label ("栄養成分表示") into candidate kcal / protein
//  values for review.
//
//  Boundaries (locked for this PR):
//   - This is the *only* place nutrition-label text is interpreted,
//     and it is intentionally Vision-free: it takes plain strings, so
//     the recognition step (`NutritionLabelScanner`) can be stubbed
//     and this logic stays trivially unit-testable.
//   - Every output field is optional. OCR is lossy and Japanese
//     labels vary, so a result may legitimately have no kcal and/or
//     no protein — the review screen asks the user to fill the gaps.
//   - Nothing here creates a MealEntry or touches DayLog. The parser
//     produces a *candidate* only; the save happens after the user
//     confirms on the review screen.
//

import Foundation

/// Candidate nutrition values extracted from a label photo. Both
/// fields are optional: a label may be partially unreadable, or a
/// value may simply be absent.
struct NutritionLabelCandidate: Equatable {
    /// Energy in kcal, if a usable value was found. kJ-only labels
    /// yield `nil` — only the kcal figure is surfaced.
    var kcal: Int?
    /// Protein in whole grams, if found. Decimal label values are
    /// rounded; `MealEntry.proteinGrams` is an `Int`.
    var proteinGrams: Int?

    /// `true` when nothing usable was extracted — the OCR view uses
    /// this to show its "読み取れませんでした" fallback.
    var isEmpty: Bool { kcal == nil && proteinGrams == nil }
}

enum NutritionLabelText {

    /// Keywords that mark a line as the energy row of a Japanese (or
    /// English) nutrition label.
    private static let energyKeywords = ["エネルギー", "熱量", "カロリー", "energy"]
    /// Keywords that mark a line as the protein row.
    private static let proteinKeywords = ["たんぱく質", "たん白質", "タンパク質", "蛋白質", "protein"]

    /// Upper sanity bounds. OCR misreads can concatenate digits; a
    /// per-serving food value far above these is treated as garbage
    /// and dropped rather than written into the review screen.
    private static let maxKcal = 100_000
    private static let maxProteinGrams = 10_000

    /// Parse a block of recognized text (newline-separated lines).
    static func parse(_ text: String) -> NutritionLabelCandidate {
        parse(lines: text.components(separatedBy: .newlines))
    }

    /// Parse recognized text already split into lines — the shape
    /// `VNRecognizeTextRequest` produces. The first line that yields
    /// a usable value wins, so on a label that lists both a
    /// per-serving and a per-100 g column the per-serving figure
    /// (printed first) is taken.
    static func parse(lines: [String]) -> NutritionLabelCandidate {
        var candidate = NutritionLabelCandidate(kcal: nil, proteinGrams: nil)
        for rawLine in lines {
            let line = normalized(rawLine)
            if line.isEmpty { continue }
            if candidate.kcal == nil, let kcal = energyValue(in: line) {
                candidate.kcal = kcal
            }
            if candidate.proteinGrams == nil, let protein = proteinValue(in: line) {
                candidate.proteinGrams = protein
            }
        }
        return candidate
    }

    // MARK: - Line interpretation

    /// kcal for a line, if it is an energy line carrying a usable
    /// number. A line counts as energy when it names an energy
    /// keyword or carries a `kcal` unit. When both `kJ` and `kcal`
    /// appear, the number attached to `kcal` wins.
    private static func energyValue(in line: String) -> Int? {
        let lower = line.lowercased()
        let keyword = energyKeywords.first { lower.contains($0.lowercased()) }
        let hasKcalUnit = lower.contains("kcal")
        guard keyword != nil || hasKcalUnit else { return nil }

        // Prefer the number immediately before a `kcal` unit so a
        // "1046kJ / 250kcal" line resolves to 250, not 1046.
        if hasKcalUnit, let attached = number(before: "kcal", in: lower) {
            return clampedInt(attached, max: maxKcal)
        }
        // Energy keyword but no explicit kcal unit (value in a
        // separate column): take the first number after the keyword.
        if let keyword {
            let tail = substring(after: keyword.lowercased(), in: lower)
            if let value = firstNumber(in: tail) {
                return clampedInt(value, max: maxKcal)
            }
        }
        return nil
    }

    /// Protein grams for a line, if it is a protein line carrying a
    /// usable number. The number is taken from *after* the protein
    /// keyword so a kcal figure earlier on a merged line is ignored.
    private static func proteinValue(in line: String) -> Int? {
        let lower = line.lowercased()
        guard let keyword = proteinKeywords.first(where: { lower.contains($0.lowercased()) }) else {
            return nil
        }
        let tail = substring(after: keyword.lowercased(), in: lower)
        guard let value = firstNumber(in: tail) else { return nil }
        return clampedInt(value, max: maxProteinGrams)
    }

    // MARK: - Number extraction

    /// The numeric literal directly preceding `unit`, e.g.
    /// `number(before: "kcal", in: "250 kcal")` → 250.
    private static func number(before unit: String, in line: String) -> Double? {
        guard let unitRange = line.range(of: unit) else { return nil }
        return trailingNumber(in: String(line[line.startIndex..<unitRange.lowerBound]))
    }

    /// The last numeric literal in `text` — the one a trailing unit
    /// would follow. Stray digits earlier in the line are ignored.
    private static func trailingNumber(in text: String) -> Double? {
        var digits = ""
        for ch in text.reversed() {
            if ch.isNumber || ch == "." {
                digits.append(ch)
            } else if digits.isEmpty {
                continue
            } else {
                break
            }
        }
        return Double(String(digits.reversed()))
    }

    /// The first numeric literal anywhere in `text`.
    private static func firstNumber(in text: String) -> Double? {
        var digits = ""
        for ch in text {
            if ch.isNumber || ch == "." {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }

    /// The portion of `text` after the first occurrence of `marker`.
    private static func substring(after marker: String, in text: String) -> String {
        guard let range = text.range(of: marker) else { return text }
        return String(text[range.upperBound...])
    }

    // MARK: - Normalization

    /// Fold full-width digits / period to half-width so labels OCR'd
    /// with full-width numerals still parse. Kana and other text are
    /// left untouched (a blanket width transform would mangle
    /// full-width katakana keywords such as タンパク質).
    private static func normalized(_ line: String) -> String {
        var result = ""
        for ch in line {
            switch ch {
            case "０"..."９":
                let scalar = ch.unicodeScalars.first!.value - 0xFF10 + 0x30
                if let half = Unicode.Scalar(scalar) {
                    result.unicodeScalars.append(half)
                } else {
                    result.append(ch)
                }
            case "．":
                result.append(".")
            default:
                result.append(ch)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Round to a non-negative whole number, dropping values past a
    /// sanity ceiling (a likely OCR misread).
    private static func clampedInt(_ value: Double, max ceiling: Int) -> Int? {
        guard value.isFinite, value >= 0 else { return nil }
        let rounded = Int(value.rounded())
        guard rounded <= ceiling else { return nil }
        return rounded
    }
}
