//
//  BarcodeScannerView.swift
//  Pulse Cue
//
//  Barcode scanner prototype. Reads packaged-food product barcodes
//  (EAN-13 / EAN-8 / UPC-E) with AVFoundation and shows the scanned
//  value for review.
//
//  Prototype boundaries (locked for this PR):
//   - Scan-and-display only. No product lookup, no Open Food Facts,
//     no network call of any kind.
//   - No MealEntry is created from a scan; NutritionLedger /
//     ProteinTotals and the day's totals are never touched here.
//   - Camera is used in the foreground only, while this screen is
//     visible. The session stops on disappear.
//
//  The symbology mapping lives in `BarcodeSymbology` so the supported
//  type set stays unit-testable without a capture session.
//

import SwiftUI
import AVFoundation
import UIKit

struct BarcodeScannerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var permission: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)
    @State private var lastScanned: ScannedBarcode?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("バーコード読み取り")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
        .task { await requestPermissionIfNeeded() }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch permission {
        case .authorized:
            scannerBody
        case .notDetermined:
            ProgressView("カメラを準備しています…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied, .restricted:
            permissionDeniedBody
        @unknown default:
            permissionDeniedBody
        }
    }

    @ViewBuilder
    private var scannerBody: some View {
        if AVCaptureDevice.default(for: .video) != nil {
            ZStack(alignment: .bottom) {
                BarcodeCameraController { scanned in
                    // Continuous scanning fires many times per second;
                    // only publish a genuinely new value so SwiftUI
                    // does not re-render every frame.
                    if scanned != lastScanned {
                        lastScanned = scanned
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                resultPanel
            }
        } else {
            cameraUnavailableBody
        }
    }

    private var resultPanel: some View {
        VStack(spacing: 8) {
            if let scanned = lastScanned {
                Text(scanned.symbology.displayLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(scanned.value)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text("読み取り専用のプロトタイプです。商品情報の検索や記録は行いません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "viewfinder")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                Text("バーコードをカメラの中央に写してください")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var permissionDeniedBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("カメラへのアクセスが必要です")
                .font(.headline)
            Text("食品バーコードを読み取るには、iOS の設定アプリでカメラの使用を許可してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cameraUnavailableBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("カメラを利用できません")
                .font(.headline)
            Text("このデバイスではカメラを使用できません。実機でお試しください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Permission

    private func requestPermissionIfNeeded() async {
        guard permission == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        permission = granted ? .authorized : .denied
    }
}

// MARK: - AVFoundation camera bridge

/// SwiftUI wrapper around the AVFoundation capture session. Kept
/// file-private: the camera plumbing has no callers outside this
/// prototype screen.
private struct BarcodeCameraController: UIViewControllerRepresentable {
    let onScan: (ScannedBarcode) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

/// Owns the `AVCaptureSession`, the metadata output and the preview
/// layer. Reports every supported barcode read through `onScan`.
private final class ScannerViewController: UIViewController,
                                           AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((ScannedBarcode) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// `startRunning()` / `stopRunning()` block; keep them off main.
    private let sessionQueue = DispatchQueue(label: "barcode.scanner.session")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // `availableMetadataObjectTypes` is only populated once the
        // output is attached. Intersect with our supported set —
        // assigning a type the hardware can't provide throws.
        output.metadataObjectTypes = BarcodeSymbology.supportedMetadataObjectTypes
            .filter { output.availableMetadataObjectTypes.contains($0) }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let scanned = ScannedBarcode(
                      value: readable.stringValue,
                      metadataObjectType: readable.type
                  ) else {
                continue
            }
            onScan?(scanned)
            return
        }
    }
}
