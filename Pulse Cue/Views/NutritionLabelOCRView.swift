//
//  NutritionLabelOCRView.swift
//  Pulse Cue
//
//  Nutrition-label OCR entry flow. Lets the user pick or capture a
//  photo of a product's nutrition label, runs on-device Apple Vision
//  text recognition, and routes the recognized values to a review
//  screen the user must confirm before anything is saved.
//
//  Flow boundaries (locked for this PR):
//   - Picking / capturing an image never saves anything. Recognition
//     produces a *candidate* `NutritionLabelCandidate`.
//   - The candidate is shown on `NutritionLabelReviewView`. A
//     MealEntry is created and DayLog is updated only when the user
//     confirms there — never directly from a scan.
//   - OCR is on-device only: no network, no cloud AI, no API key.
//   - Camera capture reuses the existing `NSCameraUsageDescription`;
//     photo-library selection uses `PhotosPicker`, which needs no
//     permission. A device without a camera falls back to library
//     selection only.
//

import SwiftUI
import PhotosUI
import UIKit

struct NutritionLabelOCRView: View {
    @Environment(\.dismiss) private var dismiss

    /// Text-recognition backend. Defaults to the on-device Vision
    /// scanner; injectable so previews can supply a stub.
    var scanner = NutritionLabelScanner()

    @State private var phase: Phase = .idle
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false

    /// Candidate to review. Set just before navigating; the review
    /// screen treats it as a draft until the user confirms.
    @State private var reviewCandidate: NutritionLabelCandidate?
    /// Whether `reviewCandidate` came from a successful recognition.
    @State private var reviewTextRecognized = false
    @State private var showReview = false

    /// Lifecycle of the (single) recognition pass.
    private enum Phase: Equatable {
        case idle
        case recognizing
        case failed
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("栄養表示を読み取る")
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
        .sheet(isPresented: $showCamera) {
            CameraImagePicker { image in
                showCamera = false
                if let image {
                    Task { await process(image) }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadAndProcess(newItem) }
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            chooserBody
        case .recognizing:
            VStack(spacing: 14) {
                ProgressView()
                Text("栄養表示を読み取り中…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            failedBody
        }
    }

    private var chooserBody: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("栄養成分表示を撮影")
                    .font(.headline)
                Text("商品パッケージの栄養成分表示を写すと、カロリーとタンパク質を読み取ります。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("写真を選ぶ", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showCamera = true
                } label: {
                    Label("カメラで撮影", systemImage: "camera")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!cameraAvailable)

                if !cameraAvailable {
                    Text("このデバイスではカメラを利用できません。写真を選んで読み取れます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("栄養表示を読み取れませんでした")
                .font(.headline)
            Text("ピントの合った明るい写真だと読み取りやすくなります。手動で入力して記録することもできます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                phase = .idle
            } label: {
                Label("別の画像を試す", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("手動で入力する") {
                presentReview(
                    NutritionLabelCandidate(kcal: nil, proteinGrams: nil),
                    textRecognized: false
                )
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var reviewDestination: some View {
        if let candidate = reviewCandidate {
            NutritionLabelReviewView(
                candidate: candidate,
                textRecognized: reviewTextRecognized,
                // A saved meal closes the whole OCR sheet so the user
                // lands back on the nutrition screen.
                onSaved: { dismiss() }
            )
        }
    }

    // MARK: - Recognition

    private func loadAndProcess(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            await process(image)
        } else {
            phase = .failed
        }
    }

    /// Runs one on-device recognition pass. On a usable result the
    /// candidate is routed to the review screen; on an unreadable
    /// image the panel shows the failure and offers manual entry.
    @MainActor
    private func process(_ image: UIImage) async {
        phase = .recognizing
        let candidate = await scanner.scan(image)
        if candidate.isEmpty {
            phase = .failed
        } else {
            presentReview(candidate, textRecognized: true)
        }
    }

    private func presentReview(
        _ candidate: NutritionLabelCandidate,
        textRecognized: Bool
    ) {
        reviewCandidate = candidate
        reviewTextRecognized = textRecognized
        phase = .idle
        photoItem = nil
        showReview = true
    }
}

// MARK: - Camera capture bridge

/// SwiftUI wrapper around `UIImagePickerController` in camera mode.
/// Kept file-private: the camera-capture plumbing has no callers
/// outside this screen. Photo-library selection uses `PhotosPicker`
/// directly and needs no bridge.
private struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
