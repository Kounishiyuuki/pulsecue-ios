//
//  OpenFoodFactsProductLookupService.swift
//  Pulse Cue
//
//  Concrete `ProductLookupService` backed by the public Open Food
//  Facts database. See `ProductLookup.swift` for the abstraction and
//  the boundaries this layer must respect.
//
//  Why Open Food Facts:
//   - Fully public: no API key, no account, no rate-limit token.
//     The lookup is a plain HTTPS GET with no credential of any kind,
//     and no private Worker URL is involved.
//   - Community-contributed, so coverage and completeness vary. The
//     decoder treats every nutrition field as optional and the
//     review screen lets the user fill or correct anything.
//
//  This type performs the *only* network request in the barcode
//  feature. It returns a `ProductLookupResult` candidate and nothing
//  else — it never creates a MealEntry and never touches DayLog.
//

import Foundation

struct OpenFoodFactsProductLookupService: ProductLookupService {
    /// Public Open Food Facts read API host. The `v0` product
    /// endpoint is the long-stable one and reports an integer
    /// `status` (1 = found, 0 = not found).
    private static let host = "https://world.openfoodfacts.org"

    /// Injected so tests can supply a stub session; production uses
    /// the shared session.
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func lookup(barcode: String) async throws -> ProductLookupResult {
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.productURL(for: trimmed) else {
            // An empty / unencodable barcode can never match a product.
            throw ProductLookupError.notFound
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // Open Food Facts asks API clients to identify themselves
        // with a User-Agent. This is not a credential or an API key —
        // it carries no secret and grants no privileged access.
        request.setValue(
            "PulseCue/1.0 (iOS; nutrition barcode lookup)",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Offline, timeout, DNS failure, … — all surface the same
            // recoverable "check your connection" message.
            throw ProductLookupError.network
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ProductLookupError.network
        }

        let payload: OFFProductResponse
        do {
            payload = try JSONDecoder().decode(OFFProductResponse.self, from: data)
        } catch {
            throw ProductLookupError.invalidResponse
        }

        // OFF returns HTTP 200 with `status: 0` for an unknown
        // barcode, so "not found" is detected from the body, not the
        // status code.
        guard payload.status == 1, let product = payload.product else {
            throw ProductLookupError.notFound
        }

        return product.makeResult(barcode: trimmed)
    }

    /// Builds the OFF product URL, requesting only the fields the
    /// review screen needs to keep the response small.
    private static func productURL(for barcode: String) -> URL? {
        guard let encoded = barcode.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return nil }
        return URL(
            string: "\(host)/api/v0/product/\(encoded).json"
                + "?fields=product_name,nutriments,serving_size"
        )
    }
}

// MARK: - Open Food Facts JSON

/// Top-level OFF product response. Only the fields used here are
/// modeled; the rest of the (large) payload is ignored.
private struct OFFProductResponse: Decodable {
    let status: Int
    let product: OFFProduct?
}

private struct OFFProduct: Decodable {
    let productName: String?
    let servingSize: String?
    let nutriments: OFFNutriments?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case servingSize = "serving_size"
        case nutriments
    }

    /// Maps the raw OFF product onto the review-screen candidate.
    /// Energy and protein are reported per 100 g; the values are
    /// surfaced as-is for the user to review and adjust.
    func makeResult(barcode: String) -> ProductLookupResult {
        ProductLookupResult(
            barcode: barcode,
            name: Self.cleaned(productName),
            kcal: nutriments?.kcalPer100g.map(Self.roundedInt),
            proteinGrams: nutriments?.proteinPer100g.map(Self.roundedInt),
            servingDescription: Self.cleaned(servingSize)
        )
    }

    /// Trims whitespace and treats an empty string as a missing
    /// value, so the review screen shows a real placeholder.
    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Rounds a per-100 g value to a whole number, clamped to a sane
    /// range so a malformed feed value can never overflow `Int`.
    ///
    /// `nonisolated` because it is a pure function with no main-actor state:
    /// this lets it be passed as a function reference to `Optional.map` (a
    /// nonisolated higher-order function) without a concurrency warning.
    private nonisolated static func roundedInt(_ value: Double) -> Int {
        Int(min(max(value, 0), 1_000_000).rounded())
    }
}

/// OFF nutriment block. Keys are hyphenated and values can arrive as
/// either a JSON number or a JSON string, so each field is decoded
/// leniently.
private struct OFFNutriments: Decodable {
    let kcalPer100g: Double?
    let proteinPer100g: Double?

    enum CodingKeys: String, CodingKey {
        case kcalPer100g = "energy-kcal_100g"
        case proteinPer100g = "proteins_100g"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kcalPer100g = OFFNutriments.lenientDouble(container, .kcalPer100g)
        proteinPer100g = OFFNutriments.lenientDouble(container, .proteinPer100g)
    }

    /// Accepts the field as a number or a numeric string; anything
    /// else (missing key, non-finite, negative) is treated as absent.
    private static func lenientDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        let raw: Double?
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            raw = value
        } else if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            raw = Double(string)
        } else {
            raw = nil
        }
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return raw
    }
}
