//
//  ProductLookup.swift
//  Pulse Cue
//
//  Abstraction for looking up packaged-food nutrition data from a
//  barcode. The barcode scanner (PR #44) produces a code; this layer
//  turns that code into a *candidate* `ProductLookupResult` the user
//  must review before anything is saved.
//
//  Boundaries (locked for this PR):
//   - A lookup result is a candidate only. It never touches DayLog,
//     never creates a MealEntry, and never updates NutritionLedger /
//     ProteinTotals totals. The save happens only after the user
//     confirms on the review screen.
//   - Public data source only (Open Food Facts). No API key, no
//     private Worker URL, no account.
//   - Open Food Facts is community-contributed and frequently
//     incomplete — every field on `ProductLookupResult` is optional
//     so the review UI can ask the user to fill the gaps.
//

import Foundation

/// One barcode lookup outcome, reduced to the fields the review
/// screen needs. All nutrition fields are optional: a found product
/// may still be missing calories or protein.
struct ProductLookupResult: Equatable {
    /// The scanned barcode this result was looked up from.
    let barcode: String
    /// Product name as reported by the data source, if any.
    let name: String?
    /// Calories, if the source had a usable value. Open Food Facts
    /// reports energy per 100 g — the value is surfaced as-is for the
    /// user to review and adjust.
    let kcal: Int?
    /// Protein grams, if available (per 100 g, same caveat as `kcal`).
    let proteinGrams: Int?
    /// Free-text serving description (e.g. "30 g"), shown read-only
    /// for context. Not parsed into a number in this PR.
    let servingDescription: String?
}

/// Why a lookup did not yield a usable product.
enum ProductLookupError: Error, Equatable {
    /// The data source has no product for this barcode.
    case notFound
    /// The request failed to reach the source (offline, timeout, …).
    case network
    /// A response arrived but could not be decoded.
    case invalidResponse

    /// User-facing Japanese message for the review screen.
    var userMessage: String {
        switch self {
        case .notFound:
            return "この商品は見つかりませんでした。手動で入力できます。"
        case .network:
            return "商品情報を取得できませんでした。通信状況を確認してください。"
        case .invalidResponse:
            return "商品情報の読み取りに失敗しました。手動で入力できます。"
        }
    }
}

/// Looks up product nutrition data for a barcode. Async so the
/// implementation can perform a network request; the protocol itself
/// makes no networking assumption, which keeps it trivially mockable
/// in tests.
protocol ProductLookupService {
    func lookup(barcode: String) async throws -> ProductLookupResult
}
