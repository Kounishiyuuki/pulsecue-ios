//
//  PhotoFoodCaptureView.swift
//  Pulse Cue
//
//  Local photo food capture prototype — the first UI shell of the
//  future photo food estimation flow documented in
//  Docs/photo-food-estimation-flow.md.
//
//  Scope boundaries (locked for this PR):
//   - Local only: photo-library selection / camera capture and an
//     in-memory preview. No AI, no network, no nutrition estimation.
//   - Nothing is saved: no MealEntry is created, DayLog is never
//     touched, and the picked image is held in view state only —
//     never written to disk or SwiftData.
//   - Estimation (photo → candidate → review → confirm → save) is
//     future work; this screen states that explicitly.
//

import SwiftUI
import PhotosUI
import UIKit

struct PhotoFoodCaptureView: View {
    @Environment(\.dismiss) private var dismiss

    /// Photo estimation provider. Defaults to the offline mock;
    /// injectable so a real provider (or a test stub) can replace it
    /// without changing this screen.
    var estimator: any PhotoFoodEstimating = MockPhotoFoodEstimator()

    @State private var photoItem: PhotosPickerItem?
    /// The picked / captured image, held in memory only — discarded
    /// when the sheet closes. Never persisted.
    @State private var selectedImage: UIImage?
    @State private var showCamera = false

    /// The mock estimation candidate to review. Set just before
    /// navigating; the review screen treats it as a draft until the
    /// user confirms.
    @State private var reviewEstimate: PhotoFoodEstimate?
    @State private var showReview = false

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    helperText
                    if let image = selectedImage {
                        previewSection(image)
                        mockEstimateSection
                    } else {
                        emptyState
                    }
                    pickerControls
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("食事写真")
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
                if let image { selectedImage = image }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadImage(newItem) }
        }
    }

    // MARK: - Sections

    private var helperText: some View {
        Text("写真を選び「モック推定を試す」を押すと、確認画面で内容を編集して保存できます。実 AI による推定は今後対応予定です。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
            Text("食事の写真を選ぶか、撮影してください")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func previewSection(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("選択中の写真")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.4), lineWidth: 0.6)
                )
                .accessibilityLabel("選択中の食事写真")
        }
    }

    /// Runs the mock estimation and routes the candidate to the
    /// review screen. The estimate is mock-only — no real AI, no
    /// network, no photo upload — and the copy here says so.
    private var mockEstimateSection: some View {
        VStack(spacing: 10) {
            Button {
                Task { await runEstimation() }
            } label: {
                Label("モック推定を試す", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("これは実 AI ではありません。今後の推定フローを確認するためのモック候補を表示します。写真は保存・送信されません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var reviewDestination: some View {
        if let estimate = reviewEstimate {
            PhotoEstimateReviewView(
                estimate: estimate,
                // A saved meal closes the whole capture sheet so the
                // user lands back on the nutrition screen.
                onSaved: { dismiss() }
            )
        }
    }

    /// Runs the photo estimation provider and routes the resulting
    /// candidate to the review screen. The default provider is the
    /// offline, deterministic mock — no network or photo upload
    /// occurs. A failed estimate simply does not navigate.
    @MainActor
    private func runEstimation() async {
        // The selected/captured image is wrapped in a local input
        // value and handed to the provider. It is never uploaded or
        // persisted; the current mock provider ignores it entirely.
        let input = PhotoFoodEstimationInput(image: selectedImage)
        guard let estimate = try? await estimator.estimate(input: input) else { return }
        reviewEstimate = estimate
        showReview = true
    }

    private var pickerControls: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(
                    selectedImage == nil ? "写真を選ぶ" : "写真を変更",
                    systemImage: "photo.on.rectangle"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                showCamera = true
            } label: {
                Label("カメラで撮る", systemImage: "camera")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!cameraAvailable)

            if !cameraAvailable {
                Text("このデバイスではカメラを利用できません。写真を選んでプレビューできます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Image loading

    /// Loads the picked library item into an in-memory `UIImage`.
    /// Nothing is persisted — the image lives only in view state and
    /// is discarded when the sheet closes.
    private func loadImage(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            selectedImage = image
        }
    }
}

// MARK: - Camera capture bridge

/// SwiftUI wrapper around `UIImagePickerController` in camera mode.
/// File-private: the camera-capture plumbing has no callers outside
/// this screen. Photo-library selection uses `PhotosPicker` directly.
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
