//
//  NutritionLabelScanner.swift
//  Pulse Cue
//
//  On-device text recognition for nutrition-label photos, backed by
//  Apple Vision. See `NutritionLabelText.swift` for the parsing
//  abstraction and the boundaries this layer respects.
//
//  Why local Vision:
//   - Fully on-device: no network request, no cloud AI, no OpenAI,
//     no API key, no Worker URL. The recognition runs entirely on the
//     phone.
//   - Vision only produces *text*. The interpretation into kcal /
//     protein candidates lives in `NutritionLabelText`, which is
//     pure and unit-tested — this type is the thin, hard-to-test
//     boundary kept deliberately small.
//
//  This type performs no persistence: it returns a
//  `NutritionLabelCandidate` and nothing else — it never creates a
//  MealEntry and never touches DayLog.
//

import Foundation
import Vision
import UIKit

struct NutritionLabelScanner {

    /// Recognize text in `image` using on-device Vision. Returns the
    /// recognized strings (top candidate per observation). An empty
    /// array means nothing readable was found; the caller surfaces
    /// the manual-entry fallback.
    func recognizeText(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            // Recognition is CPU-heavy and blocking; keep it off the
            // calling (often main) actor.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // On-device Japanese + English label text.
                request.recognitionLanguages = ["ja-JP", "en-US"]

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let lines = observations.compactMap {
                        $0.topCandidates(1).first?.string
                    }
                    continuation.resume(returning: lines)
                } catch {
                    // A Vision failure is treated the same as an
                    // unreadable image — the UI offers manual entry.
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Recognize text and parse it into a candidate in one call. A
    /// fully unreadable image yields an empty `NutritionLabelCandidate`.
    func scan(_ image: UIImage) async -> NutritionLabelCandidate {
        NutritionLabelText.parse(lines: await recognizeText(in: image))
    }
}
