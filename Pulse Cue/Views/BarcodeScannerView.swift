//
//  BarcodeScannerView.swift
//  Pulse Cue
//
//  Barcode scanner for packaged-food products. Reads EAN-13 / EAN-8 /
//  UPC-E codes with AVFoundation, then offers an Open Food Facts
//  lookup whose result the user reviews before anything is saved.
//
//  Flow boundaries (locked for this PR):
//   - Scanning never saves anything. Tapping 「栄養情報を調べる」
//     performs one Open Food Facts lookup and produces a *candidate*
//     `ProductLookupResult`.
//   - The candidate is shown on `BarcodeProductReviewView`. A
//     MealEntry is created and DayLog is updated only when the user
//     confirms there — never directly from a scan or a lookup.
//   - Camera is used in the foreground only, while the scanner is
//     visible. The session stops on disappear (including when the
//     review screen is pushed on top).
//
//  The symbology mapping lives in `BarcodeSymbology` and the lookup
//  contract in `ProductLookup.swift`, so both stay unit-testable
//  without a capture session or a network call.
//

import SwiftUI
import AVFoundation
import UIKit

struct BarcodeScannerView: View {
    @Environment(\.dismiss) private var dismiss

    /// Product lookup backend. Defaults to the public Open Food Facts
    /// service; injectable so previews / tests can supply a stub.
    var lookupService: any ProductLookupService = OpenFoodFactsProductLookupService()

    @State private var permission: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)
    @State private var lastScanned: ScannedBarcode?
    @State private var lookupPhase: LookupPhase = .idle

    /// Candidate to review. Set just before navigating; the review
    /// screen treats it as a draft until the user confirms.
    @State private var reviewCandidate: ProductLookupResult?
    /// Whether `reviewCandidate` came from a real product match.
    @State private var reviewProductFound = false
    @State private var showReview = false

    /// Lifecycle of the (single) Open Food Facts request.
    private enum LookupPhase: Equatable {
        case idle
        case loading
        case failed(ProductLookupError)
    }

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
                .navigationDestination(isPresented: $showReview) {
                    reviewDestination
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
                    // only react to a genuinely new value so SwiftUI
                    // does not re-render every frame, and reset any
                    // stale lookup state from the previous code.
                    if scanned != lastScanned {
                        lastScanned = scanned
                        lookupPhase = .idle
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                resultPanel
            }
        } else {
            cameraUnavailableBody
        }
    }

    // MARK: - Result panel

    private var resultPanel: some View {
        VStack(spacing: 12) {
            if let scanned = lastScanned {
                scannedHeader(scanned)
                lookupControls(for: scanned)
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

    private func scannedHeader(_ scanned: ScannedBarcode) -> some View {
        VStack(spacing: 4) {
            Text(scanned.symbology.displayLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(scanned.value)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func lookupControls(for scanned: ScannedBarcode) -> some View {
        switch lookupPhase {
        case .idle:
            Button {
                startLookup(for: scanned.value)
            } label: {
                Label("栄養情報を調べる", systemImage: "magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("商品情報を取得中…")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

        case .failed(let error):
            VStack(spacing: 10) {
                Text(error.userMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if error == .network {
                    Button {
                        startLookup(for: scanned.value)
                    } label: {
                        Label("再試行", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("手動で入力する") {
                    presentReview(
                        candidate: ProductLookupResult(
                            barcode: scanned.value,
                            name: nil,
                            kcal: nil,
                            proteinGrams: nil,
                            servingDescription: nil
                        ),
                        productFound: false
                    )
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private var reviewDestination: some View {
        if let candidate = reviewCandidate {
            BarcodeProductReviewView(
                candidate: candidate,
                productFound: reviewProductFound,
                // A saved meal closes the whole scanner sheet so the
                // user lands back on the nutrition screen.
                onSaved: { dismiss() }
            )
        }
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

    // MARK: - Lookup

    /// Runs one Open Food Facts lookup. On success the candidate is
    /// routed to the review screen; on failure the panel shows the
    /// error and offers retry / manual entry.
    private func startLookup(for barcode: String) {
        lookupPhase = .loading
        Task {
            do {
                let result = try await lookupService.lookup(barcode: barcode)
                presentReview(candidate: result, productFound: true)
            } catch let error as ProductLookupError {
                lookupPhase = .failed(error)
            } catch {
                lookupPhase = .failed(.network)
            }
        }
    }

    private func presentReview(candidate: ProductLookupResult, productFound: Bool) {
        reviewCandidate = candidate
        reviewProductFound = productFound
        lookupPhase = .idle
        showReview = true
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
/// screen.
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
