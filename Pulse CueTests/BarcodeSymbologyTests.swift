//
//  BarcodeSymbologyTests.swift
//  Pulse CueTests
//
//  Locks in the pure (non-camera) logic behind the barcode scanner
//  prototype: the symbology <-> AVFoundation type mapping and the
//  `ScannedBarcode` factory.
//
//  Coverage:
//   - every symbology round-trips through its AVMetadataObject.ObjectType
//   - display labels are stable
//   - the supported-type set is exactly EAN-13 / EAN-8 / UPC-E
//   - unsupported metadata types (QR, PDF417) are rejected
//   - ScannedBarcode rejects empty / nil values and unsupported types
//   - ScannedBarcode keeps the value + symbology it was built with
//

import AVFoundation
import Testing
@testable import Pulse_Cue

struct BarcodeSymbologyTests {

    // MARK: - Symbology mapping

    @Test func eachSymbologyRoundTripsThroughMetadataType() {
        for symbology in BarcodeSymbology.allCases {
            let type = symbology.metadataObjectType
            #expect(BarcodeSymbology(metadataObjectType: type) == symbology)
        }
    }

    @Test func metadataTypesAreTheExpectedProductCodes() {
        #expect(BarcodeSymbology.ean13.metadataObjectType == .ean13)
        #expect(BarcodeSymbology.ean8.metadataObjectType == .ean8)
        #expect(BarcodeSymbology.upce.metadataObjectType == .upce)
    }

    @Test func displayLabelsAreStable() {
        #expect(BarcodeSymbology.ean13.displayLabel == "EAN-13")
        #expect(BarcodeSymbology.ean8.displayLabel == "EAN-8")
        #expect(BarcodeSymbology.upce.displayLabel == "UPC-E")
    }

    @Test func supportedMetadataObjectTypesAreExactlyTheProductSet() {
        let supported = Set(BarcodeSymbology.supportedMetadataObjectTypes)
        #expect(supported == [.ean13, .ean8, .upce])
        #expect(BarcodeSymbology.supportedMetadataObjectTypes.count == 3)
    }

    @Test func unsupportedMetadataTypesAreRejected() {
        // QR / PDF417 are intentionally out of scope for the
        // product-barcode prototype.
        #expect(BarcodeSymbology(metadataObjectType: .qr) == nil)
        #expect(BarcodeSymbology(metadataObjectType: .pdf417) == nil)
        #expect(BarcodeSymbology(metadataObjectType: .aztec) == nil)
    }

    // MARK: - ScannedBarcode factory

    @Test func scannedBarcodeBuildsFromSupportedRead() {
        let scanned = ScannedBarcode(value: "4901234567894", metadataObjectType: .ean13)
        #expect(scanned != nil)
        #expect(scanned?.value == "4901234567894")
        #expect(scanned?.symbology == .ean13)
    }

    @Test func scannedBarcodeRejectsNilValue() {
        #expect(ScannedBarcode(value: nil, metadataObjectType: .ean13) == nil)
    }

    @Test func scannedBarcodeRejectsEmptyValue() {
        #expect(ScannedBarcode(value: "", metadataObjectType: .ean13) == nil)
    }

    @Test func scannedBarcodeRejectsUnsupportedType() {
        // A QR code with a perfectly valid string value must still be
        // rejected — the prototype only surfaces product barcodes.
        #expect(ScannedBarcode(value: "https://example.com", metadataObjectType: .qr) == nil)
    }

    @Test func scannedBarcodeDirectInitKeepsFields() {
        let scanned = ScannedBarcode(value: "12345678", symbology: .ean8)
        #expect(scanned.value == "12345678")
        #expect(scanned.symbology == .ean8)
    }

    @Test func scannedBarcodeEquatableComparesValueAndSymbology() {
        let a = ScannedBarcode(value: "4901234567894", symbology: .ean13)
        let b = ScannedBarcode(value: "4901234567894", symbology: .ean13)
        let c = ScannedBarcode(value: "0123456", symbology: .upce)
        #expect(a == b)
        #expect(a != c)
    }
}
