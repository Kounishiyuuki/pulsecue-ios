//
//  RunnerView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI

struct RunnerView: View {
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showRoutinePicker = false
    @State private var showEndAlert = false

    var body: some View {
        VStack(spacing: 16) {
            header
            nowCard
            restCard
            nextCard

            Toggle("画面を常時点灯", isOn: $settings.keepScreenOn)
                .toggleStyle(.switch)
                .padding(.top, 4)

            if runnerViewModel.isRunning {
                Button("セッション終了") {
                    showEndAlert = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .alert("セッションを終了しますか？", isPresented: $showEndAlert) {
                    Button("終了", role: .destructive) {
                        runnerViewModel.endSessionEarly()
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("このセッションは中断として保存されます。")
                }
            } else {
                Button("ルーティン開始") {
                    showRoutinePicker = true
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer(minLength: 12)
        }
        .padding()
        .navigationTitle("ランナー")
        .sheet(isPresented: $showRoutinePicker) {
            RoutinePickerSheet()
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                runnerViewModel.appDidBecomeActive()
            } else if newPhase == .background {
                runnerViewModel.appDidEnterBackground()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusTitle)
                .font(.headline)
            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var nowCard: some View {
        RunnerCard(title: "今") {
            if let step = runnerViewModel.currentStep {
                Text(step.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("セット \(runnerViewModel.currentSetIndex + 1) / \(step.sets)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("進行中の種目はありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var restCard: some View {
        RunnerCard(title: "休憩") {
            if runnerViewModel.phase == .rest {
                Text(DateUtils.formatDuration(seconds: runnerViewModel.remainingSeconds))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
            } else {
                Text("--:--")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(runnerViewModel.needsAttention ? Color.orange : Color.clear, lineWidth: 3)
        )
    }

    private var nextCard: some View {
        RunnerCard(title: "次") {
            if let step = runnerViewModel.nextStep {
                Text(step.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("セット数 \(step.sets)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("セッション終了")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                runnerViewModel.handle(action: .back)
            } label: {
                Label("戻る", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)

            Button {
                runnerViewModel.handle(action: .skip)
            } label: {
                Label("スキップ", systemImage: "forward.fill")
            }
            .buttonStyle(.bordered)

            Button {
                runnerViewModel.handle(action: .extend)
            } label: {
                Label("+10秒", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(runnerViewModel.phase != .rest)

            Button {
                runnerViewModel.handle(action: .complete)
            } label: {
                Label("完了", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var statusTitle: String {
        if runnerViewModel.phase == .rest {
            return "休憩中"
        }
        if runnerViewModel.isRunning {
            return "実行中"
        }
        return "準備完了"
    }

    private var statusSubtitle: String {
        if runnerViewModel.phase == .rest {
            return "次のセットまで休憩"
        }
        if runnerViewModel.isRunning {
            return "テンポを維持しましょう"
        }
        return "ルーティンを開始してください"
    }
}

private struct RunnerCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
