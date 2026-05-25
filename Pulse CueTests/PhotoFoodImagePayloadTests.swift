//
//  PhotoFoodImagePayloadTests.swift
//  Pulse CueTests
//
//  Tests for the local image-payload helper. The helper resizes and
//  re-encodes a `UIImage` entirely on-device — no networking, no
//  persistence — so these tests synthesise small UIImages in-process
//  and assert the produced JPEG payload's shape and metadata. No real
//  photos and no network are involved.
//

import Testing
import UIKit
@testable import Pulse_Cue

struct PhotoFoodImagePayloadTests {

    /// Synthesise a tiny solid-colour image so dimensions are exact
    /// and deterministic (no rendering of system assets).
    private func makeImage(width: Int, height: Int) -> UIImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Fill with an opaque grey so JPEG encoding actually has
        // something to compress.
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return UIImage(cgImage: context.makeImage()!)
    }

    /// Synthesise a striped image whose high-frequency content makes
    /// JPEG compression quality observable in byte size (a flat fill
    /// compresses to ~the same size at any quality).
    private func makePatternedImage(width: Int, height: Int) -> UIImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // 2-pixel alternating stripes of two strongly different
        // colours — lots of edges for the JPEG quantiser to chew on.
        for y in stride(from: 0, to: height, by: 2) {
            let isEven = (y / 2) % 2 == 0
            if isEven {
                context.setFillColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1)
            } else {
                context.setFillColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1)
            }
            context.fill(CGRect(x: 0, y: y, width: width, height: 2))
        }
        return UIImage(cgImage: context.makeImage()!)
    }

    // MARK: - Output shape

    @Test func payloadHasJpegMimeType() throws {
        let payload = try PhotoFoodImagePayloadPreparer.prepare(from: makeImage(width: 64, height: 64))
        #expect(payload.mimeType == "image/jpeg")
    }

    @Test func payloadByteCountIsPositive() throws {
        let payload = try PhotoFoodImagePayloadPreparer.prepare(from: makeImage(width: 64, height: 64))
        #expect(payload.byteCount > 0)
        #expect(payload.byteCount == payload.data.count)
    }

    // MARK: - Resizing

    @Test func smallImagesAreNotUpscaled() throws {
        // A 200×200 source should come out at 200×200 — never inflated
        // to the 1280 default. Saves bytes and keeps fidelity.
        let payload = try PhotoFoodImagePayloadPreparer.prepare(from: makeImage(width: 200, height: 200))
        #expect(payload.pixelWidth == 200)
        #expect(payload.pixelHeight == 200)
    }

    @Test func largeImagesAreResizedDownToMaxPixelDimension() throws {
        // A 4000×3000 source must be scaled so the longest side is
        // at most the default 1280.
        let payload = try PhotoFoodImagePayloadPreparer.prepare(from: makeImage(width: 4000, height: 3000))
        let longestSide = max(payload.pixelWidth, payload.pixelHeight)
        #expect(longestSide <= 1280)
    }

    @Test func customMaxPixelDimensionIsHonored() throws {
        // Passing a tighter cap takes precedence over the default.
        let payload = try PhotoFoodImagePayloadPreparer.prepare(
            from: makeImage(width: 4000, height: 3000),
            maxPixelDimension: 512
        )
        let longestSide = max(payload.pixelWidth, payload.pixelHeight)
        #expect(longestSide <= 512)
    }

    @Test func aspectRatioIsRoughlyPreserved() throws {
        // 4:3 source → 4:3 output (within a 1-pixel rounding error).
        let payload = try PhotoFoodImagePayloadPreparer.prepare(from: makeImage(width: 4000, height: 3000))
        let sourceRatio = 4000.0 / 3000.0
        let outRatio = Double(payload.pixelWidth) / Double(payload.pixelHeight)
        #expect(abs(outRatio - sourceRatio) < 0.01)
    }

    @Test func portraitAspectIsPreservedToo() throws {
        // 9:16 portrait → 9:16 output.
        let payload = try PhotoFoodImagePayloadPreparer.prepare(from: makeImage(width: 1800, height: 3200))
        #expect(payload.pixelHeight > payload.pixelWidth)
        let sourceRatio = 1800.0 / 3200.0
        let outRatio = Double(payload.pixelWidth) / Double(payload.pixelHeight)
        #expect(abs(outRatio - sourceRatio) < 0.01)
    }

    // MARK: - Compression / determinism

    @Test func compressionQualityAffectsByteCount() throws {
        // Higher quality should produce more bytes than lower quality
        // for the same source. Use a patterned image so the JPEG
        // quantiser actually has high-frequency content to discard.
        let source = makePatternedImage(width: 800, height: 600)
        let high = try PhotoFoodImagePayloadPreparer.prepare(from: source, compressionQuality: 0.9)
        let low = try PhotoFoodImagePayloadPreparer.prepare(from: source, compressionQuality: 0.2)
        #expect(high.byteCount > low.byteCount)
    }

    @Test func preparingTheSameImageTwiceIsDeterministic() throws {
        // Same source + same parameters should yield equal payloads
        // — important for retry / dedup logic to be predictable.
        let source = makeImage(width: 256, height: 256)
        let a = try PhotoFoodImagePayloadPreparer.prepare(from: source)
        let b = try PhotoFoodImagePayloadPreparer.prepare(from: source)
        #expect(a == b)
    }

    // MARK: - Error cases

    @Test func zeroSizeImageThrowsEncodingFailed() {
        // An empty `UIImage()` has no CGImage and zero pixel area;
        // the helper rejects it rather than returning empty bytes.
        #expect(throws: PhotoFoodImagePayloadError.encodingFailed) {
            try PhotoFoodImagePayloadPreparer.prepare(from: UIImage())
        }
    }
}
