//
//  BarcodeSymbology.swift
//  Pulse Cue
//
//  Pure mapping layer for the barcode scanner prototype. Keeps the
//  set of supported product-barcode symbologies — and their mapping
//  to / from AVFoundation's `AVMetadataObject.ObjectType` — in one
//  place that can be unit-tested without spinning up an
//  `AVCaptureSession` or touching the camera.
//
//  Scope: this prototype only *reads and displays* barcode values.
//  There is no product lookup, no Open Food Facts call, and no
//  MealEntry creation. Symbology classification stops at "what kind
//  of barcode is this" — nutrition data parsing is a later PR.
//
//  QR codes are intentionally excluded: the prototype targets
//  packaged-food product codes (JAN/EAN/UPC), and a narrower type
//  set means fewer false reads from unrelated 2D codes.
//

import AVFoundation

/// Product barcode symbologies the scanner prototype recognizes.
enum BarcodeSymbology: String, CaseIterable {
    case ean13
    case ean8
    case upce

    /// The AVFoundation metadata type this symbology maps to. Used
    /// when configuring `AVCaptureMetadataOutput.metadataObjectTypes`.
    var metadataObjectType: AVMetadataObject.ObjectType {
        switch self {
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .upce: return .upce
        }
    }

    /// Human-readable label shown next to a scanned value in the
    /// review UI.
    var displayLabel: String {
        switch self {
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upce: return "UPC-E"
        }
    }

    /// Reverse lookup from an AVFoundation metadata type. Returns nil
    /// for any type outside the supported product-barcode set (e.g.
    /// QR, PDF417) so callers can ignore unrelated reads.
    init?(metadataObjectType: AVMetadataObject.ObjectType) {
        switch metadataObjectType {
        case .ean13: self = .ean13
        case .ean8: self = .ean8
        case .upce: self = .upce
        default: return nil
        }
    }

    /// Every metadata type the capture session should watch for.
    static var supportedMetadataObjectTypes: [AVMetadataObject.ObjectType] {
        allCases.map(\.metadataObjectType)
    }
}

/// One scanned barcode, reduced to the value + symbology the review
/// UI needs. Deliberately carries no nutrition fields — this
/// prototype does not look up or store product data.
struct ScannedBarcode: Equatable {
    let value: String
    let symbology: BarcodeSymbology

    /// Build a result from a raw AVFoundation read. Returns nil when
    /// the metadata type is unsupported or the string value is empty,
    /// so the scanner can simply skip junk reads.
    init?(value: String?, metadataObjectType: AVMetadataObject.ObjectType) {
        guard let value, !value.isEmpty,
              let symbology = BarcodeSymbology(metadataObjectType: metadataObjectType) else {
            return nil
        }
        self.value = value
        self.symbology = symbology
    }

    /// Direct initializer for tests / non-AVFoundation call sites.
    init(value: String, symbology: BarcodeSymbology) {
        self.value = value
        self.symbology = symbology
    }
}
