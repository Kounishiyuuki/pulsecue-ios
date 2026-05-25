//
//  PhotoFoodImagePayload.swift
//  Pulse Cue
//
//  Local image-payload helper for the future photo AI request
//  boundary (see `Docs/photo-ai-backend-token-spec.md` §6 and §7).
//  Resizes and JPEG-encodes a `UIImage` entirely on-device — never
//  uploads, never persists, never logs the bytes. The resulting
//  `PhotoFoodImagePayload` is the byte form a future real provider
//  (planned for PR 65) would hand to the PulseCue backend; today the
//  helper is prepared and tested in isolation so the encoding rules
//  are locked in before any networking code is added.
//
//  Boundaries (locked for this PR):
//   - Local only. No networking, no persistence, no logging. The
//     produced bytes live in memory inside the returned struct.
//   - Re-rendering through `UIGraphicsImageRenderer` naturally drops
//     EXIF (incl. GPS) from the source image — the helper returns a
//     fresh JPEG bitmap with no embedded metadata, satisfying the
//     EXIF-scrub requirement.
//   - The mock photo estimation flow continues to ignore its input
//     entirely, so this PR adds no user-visible behaviour change.
//

import Foundation
import UIKit

/// A prepared, in-memory image payload ready to be handed to a future
/// photo AI request. Plain value type — it carries the encoded bytes
/// and their shape, nothing else.
struct PhotoFoodImagePayload: Equatable, Sendable {
    /// Encoded image bytes (JPEG today).
    let data: Data
    /// IANA MIME type of `data`.
    let mimeType: String
    /// Pixel width of the encoded image (post-resize).
    let pixelWidth: Int
    /// Pixel height of the encoded image (post-resize).
    let pixelHeight: Int

    /// Convenience size of the payload in bytes.
    var byteCount: Int { data.count }
}

/// Errors raised when an image cannot be turned into a payload.
enum PhotoFoodImagePayloadError: Error, Equatable {
    /// The renderer or JPEG encoder failed to produce bytes — e.g. a
    /// zero-size source image or one with a missing/corrupt CGImage.
    case encodingFailed
}

/// Prepares a `PhotoFoodImagePayload` from a local `UIImage`.
///
/// Behaviour:
///  - Resizes the image down so its longest pixel side is at most
///    `maxPixelDimension`, preserving aspect ratio.
///  - Small images are *not* upscaled — preparing a 200×200 image
///    with `maxPixelDimension: 1280` returns a 200×200 JPEG.
///  - Encodes the resized bitmap as JPEG at `compressionQuality`.
///  - EXIF / GPS / camera metadata is dropped: the result is a
///    freshly rendered bitmap, not a re-wrap of the original file.
///
/// No networking, no persistence, no logging.
enum PhotoFoodImagePayloadPreparer {

    /// Prepare a JPEG payload from `image`.
    /// - Parameters:
    ///   - image: the source image (in memory).
    ///   - maxPixelDimension: upper bound for the longest pixel side
    ///     of the output. Default `1280` matches the request-shape
    ///     guidance in `Docs/photo-ai-backend-token-spec.md`.
    ///   - compressionQuality: JPEG quality in `[0, 1]`. Default
    ///     `0.8` is a reasonable size/quality trade-off for food
    ///     photos.
    /// - Throws: `PhotoFoodImagePayloadError.encodingFailed` if the
    ///   source has zero pixel area or the JPEG encoder returns no
    ///   bytes.
    static func prepare(
        from image: UIImage,
        maxPixelDimension: CGFloat = 1280,
        compressionQuality: CGFloat = 0.8
    ) throws -> PhotoFoodImagePayload {
        // Use the CGImage's actual pixel dimensions when available so
        // the helper is independent of `UIImage.scale` (which can
        // vary with the source — Photos picker vs. camera vs. test
        // fixture). Fall back to `size * scale` otherwise.
        let sourcePixelSize: CGSize
        if let cgImage = image.cgImage {
            sourcePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            sourcePixelSize = CGSize(
                width: image.size.width * image.scale,
                height: image.size.height * image.scale
            )
        }

        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
            throw PhotoFoodImagePayloadError.encodingFailed
        }

        // Don't upscale: keep the source size if it already fits,
        // otherwise scale down preserving aspect ratio.
        let longestSide = max(sourcePixelSize.width, sourcePixelSize.height)
        let scale = longestSide > maxPixelDimension ? maxPixelDimension / longestSide : 1
        let targetPixelSize = CGSize(
            width: max(1, (sourcePixelSize.width * scale).rounded()),
            height: max(1, (sourcePixelSize.height * scale).rounded())
        )

        // Render at scale 1.0 so the bitmap's pixel size equals the
        // size we asked for. `opaque: true` keeps the JPEG smaller
        // (food photos rarely need an alpha channel).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetPixelSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetPixelSize))
        }

        guard
            let data = resized.jpegData(compressionQuality: compressionQuality),
            !data.isEmpty
        else {
            throw PhotoFoodImagePayloadError.encodingFailed
        }

        // Report the rendered image's actual pixel dimensions, in
        // case the renderer normalized our target.
        let outWidth: Int
        let outHeight: Int
        if let renderedCG = resized.cgImage {
            outWidth = renderedCG.width
            outHeight = renderedCG.height
        } else {
            outWidth = Int(targetPixelSize.width)
            outHeight = Int(targetPixelSize.height)
        }

        return PhotoFoodImagePayload(
            data: data,
            mimeType: "image/jpeg",
            pixelWidth: outWidth,
            pixelHeight: outHeight
        )
    }
}
