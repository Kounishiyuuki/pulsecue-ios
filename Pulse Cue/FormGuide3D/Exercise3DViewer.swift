//
//  Exercise3DViewer.swift
//  Pulse Cue
//
//  SwiftUI wrapper for the RealityKit form-guide scene. Thin: it hosts the
//  `.nonAR` ARView via a representable, overlays orbit/zoom gestures on the
//  scene area only (so they never fight sheet scrolling or the control
//  buttons), and renders accessible playback/camera controls driven by
//  `Exercise3DSceneController`.
//

import SwiftUI
import RealityKit

/// Hosts the controller's `.nonAR` ARView. The ARView is created once.
private struct Exercise3DRepresentable: UIViewRepresentable {
    let controller: Exercise3DSceneController

    func makeUIView(context: Context) -> ARView {
        controller.makeARView()
    }
    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        // Belt-and-suspenders: stop the AR view rendering if it is torn down
        // without an explicit controller.teardown().
        uiView.scene.anchors.removeAll()
    }
}

struct Exercise3DViewer: View {
    @ObservedObject var controller: Exercise3DSceneController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOrbiting = false
    @State private var isZooming = false

    private let sceneHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 12) {
            sceneArea
            controls
        }
    }

    // MARK: - Scene

    private var sceneArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(sceneBackground)
            Exercise3DRepresentable(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(gestureLayer)
        }
        .frame(height: sceneHeight)
        .overlay(alignment: .topLeading) { reduceMotionBadge }
        .accessibilityElement()
        .accessibilityLabel("\(profileTitle)の3Dフォームデモ")
        .accessibilityHint("下のボタンで再生・一時停止・視点変更ができます。ドラッグで回転、ピンチで拡大縮小します。")
    }

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if !isOrbiting {
                            isOrbiting = true
                            controller.beginDrag()
                        }
                        // `translation` is CUMULATIVE from gesture start; drag
                        // owns azimuth/elevation only.
                        controller.updateDrag(
                            totalTranslationX: Float(value.translation.width),
                            y: Float(value.translation.height)
                        )
                    }
                    .onEnded { _ in
                        isOrbiting = false
                        controller.endDrag()
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        if !isZooming {
                            isZooming = true
                            controller.beginPinch()
                        }
                        controller.updatePinch(magnification: Float(scale)) // owns distance only
                    }
                    .onEnded { _ in
                        isZooming = false
                        controller.endPinch()
                    }
            )
    }

    @ViewBuilder
    private var reduceMotionBadge: some View {
        if reduceMotion {
            Text("視差軽減：自動再生オフ")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.thinMaterial))
                .padding(8)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            ViewThatFits {
                HStack(spacing: 14) {
                    playbackButton
                    restartButton
                    speedControl
                }
                VStack(spacing: 8) {
                    playbackButton
                    restartButton
                    speedControl
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
                spacing: 8
            ) {
                ForEach(Exercise3DCamera.allCases, id: \.self) { preset in
                    cameraChip(preset)
                }
                Button {
                    controller.resetCamera()
                } label: {
                    Label("視点リセット", systemImage: "camera.rotate")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("視点をリセット")
            }
        }
    }

    private var playbackButton: some View {
        controlButton(
            controller.isPlaying ? "一時停止" : "再生",
            systemImage: controller.isPlaying ? "pause.fill" : "play.fill"
        ) { controller.togglePlay() }
    }

    private var restartButton: some View {
        controlButton("最初から", systemImage: "arrow.counterclockwise") {
            controller.restart()
            if !reduceMotion { controller.play() }
        }
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(title)
    }

    private var speedControl: some View {
        HStack(spacing: 6) {
            speedChip(0.5, "0.5x")
            speedChip(1.0, "1.0x")
        }
    }

    private func speedChip(_ value: Float, _ label: String) -> some View {
        let selected = abs(controller.speed - value) < 0.01
        return Button {
            controller.setSpeed(value)
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 52, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("再生速度 \(label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cameraChip(_ preset: Exercise3DCamera) -> some View {
        let selected = controller.camera == preset
        return Button {
            controller.setCamera(preset)
        } label: {
            Text(preset.displayName)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 52, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("視点 \(preset.displayName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sceneBackground: LinearGradient {
        LinearGradient(
            colors: [Color(white: 0.16), Color(white: 0.10)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var profileTitle: String {
        ExerciseLibrary.exercise(for: controller.profile.exerciseId)?.displayName ?? "エクササイズ"
    }
}
