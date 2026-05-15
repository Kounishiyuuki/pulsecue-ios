//
//  WorkoutPlanGenerator.swift
//  Pulse Cue
//
//  Pure, deterministic workout plan generator (v0). Given a body part
//  and the user's available machines, picks a small ordered list of
//  exercise templates whose machines are present and returns them as
//  a `GeneratedPlan` value type. No I/O, no SwiftData — the caller
//  decides what (if anything) to persist via `RoutineFactory`.
//

import Foundation

/// One exercise inside a generated plan. The shape mirrors the fields
/// `Step` cares about so `RoutineFactory` can map this 1:1.
struct GeneratedExercise: Hashable, Identifiable {
    var id: String { machineId + "::" + exerciseName }
    let machineId: String
    let exerciseName: String
    let sets: Int
    let reps: Int
    let restSeconds: Int
    /// Short Japanese coaching cue surfaced in the preview screen.
    let cue: String
}

struct GeneratedPlan: Hashable {
    let bodyPart: BodyPart
    let gymId: UUID
    let gymName: String
    let exercises: [GeneratedExercise]
    /// Human-readable warnings (e.g. "選択中のマシンが少ないためメニューが短くなっています").
    let warnings: [String]

    var isEmpty: Bool { exercises.isEmpty }

    /// Default display title for the resulting Routine.
    var defaultTitle: String {
        "\(bodyPart.displayName)の日 — \(gymName)"
    }
}

enum WorkoutPlanGenerator {

    /// Maximum number of exercises the v0 generator returns. Kept low
    /// so the preview screen fits without scrolling on iPhone SE.
    static let maxExercises = 5

    /// Below this many machines for the chosen body part, the user
    /// gets an explicit warning that the plan will be short.
    private static let minMachinesForFullPlan = 3

    /// Generates a plan from the available machines.
    /// Falls back to a non-empty exercises list whenever any of the
    /// available machines maps to a template for the body part; the
    /// `warnings` array carries the explanation when the result is
    /// thin or empty.
    static func generate(
        bodyPart: BodyPart,
        gym: Gym,
        availableMachines: [GymMachine]
    ) -> GeneratedPlan {
        let availableIds = Set(availableMachines.map(\.machineId))
        let candidates = templates(for: bodyPart).filter { availableIds.contains($0.machineId) }

        var warnings: [String] = []
        if availableMachines.isEmpty {
            warnings.append("選択中のマシンがありません。マイジムから利用できるマシンを選択してください。")
        } else if candidates.isEmpty {
            warnings.append("\(bodyPart.displayName)を鍛えられるマシンが見つかりませんでした。別のマシンを追加するか、別の部位を選んでください。")
        } else if candidates.count < minMachinesForFullPlan {
            warnings.append("選択中のマシンが少ないためメニューが短くなっています。マシンを追加するとより良い提案ができます。")
        }

        let chosen = Array(candidates.prefix(maxExercises))
        return GeneratedPlan(
            bodyPart: bodyPart,
            gymId: gym.id,
            gymName: gym.name,
            exercises: chosen.map { template in
                GeneratedExercise(
                    machineId: template.machineId,
                    exerciseName: template.exerciseName,
                    sets: template.sets,
                    reps: template.reps,
                    restSeconds: template.restSeconds,
                    cue: template.cue
                )
            },
            warnings: warnings
        )
    }

    // MARK: - Templates

    /// One canonical exercise per `(BodyPart, machineId)` pair. Order
    /// inside each body part list determines priority when the user
    /// owns more machines than the plan can show.
    private struct Template {
        let machineId: String
        let exerciseName: String
        let sets: Int
        let reps: Int
        let restSeconds: Int
        let cue: String
    }

    private static func templates(for bodyPart: BodyPart) -> [Template] {
        switch bodyPart {
        case .chest:
            return [
                Template(machineId: "bench_press", exerciseName: "ベンチプレス", sets: 4, reps: 8, restSeconds: 120, cue: "肩甲骨を寄せて胸でバーを受け止める"),
                Template(machineId: "chest_press", exerciseName: "チェストプレス", sets: 3, reps: 10, restSeconds: 90, cue: "肘は無理に伸ばし切らず胸の張りを保つ"),
                Template(machineId: "dumbbells", exerciseName: "ダンベルプレス", sets: 3, reps: 10, restSeconds: 90, cue: "下ろす時に胸の伸びを感じる"),
                Template(machineId: "pec_deck", exerciseName: "ペックフライ", sets: 3, reps: 12, restSeconds: 75, cue: "肘の角度をキープしたまま弧を描く"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルクロスオーバー", sets: 3, reps: 12, restSeconds: 60, cue: "中央で胸を絞り切る"),
                Template(machineId: "smith_machine", exerciseName: "スミスマシンベンチプレス", sets: 3, reps: 10, restSeconds: 90, cue: "バー軌道は固定。胸の高さに下ろす"),
            ]
        case .back:
            return [
                Template(machineId: "lat_pulldown", exerciseName: "ラットプルダウン", sets: 4, reps: 10, restSeconds: 90, cue: "肘で引く意識。広背筋に効かせる"),
                Template(machineId: "seated_row", exerciseName: "シーテッドロー", sets: 3, reps: 10, restSeconds: 90, cue: "胸を張って肩甲骨を寄せる"),
                Template(machineId: "pull_up_bar", exerciseName: "プルアップ", sets: 3, reps: 8, restSeconds: 120, cue: "顎をバーまで。下ろす時もコントロール"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルロー", sets: 3, reps: 12, restSeconds: 75, cue: "ハンドルをみぞおちに引く"),
                Template(machineId: "back_extension", exerciseName: "バックエクステンション", sets: 3, reps: 12, restSeconds: 60, cue: "背中で起こす。反らしすぎ注意"),
                Template(machineId: "dumbbells", exerciseName: "ワンハンドダンベルロー", sets: 3, reps: 10, restSeconds: 75, cue: "脇腹に引き付けるイメージ"),
            ]
        case .legs:
            return [
                Template(machineId: "leg_press", exerciseName: "レッグプレス", sets: 4, reps: 10, restSeconds: 120, cue: "膝はつま先と同じ向き"),
                Template(machineId: "leg_extension", exerciseName: "レッグエクステンション", sets: 3, reps: 12, restSeconds: 75, cue: "上で1秒キープして大腿四頭筋を絞る"),
                Template(machineId: "leg_curl", exerciseName: "レッグカール", sets: 3, reps: 12, restSeconds: 75, cue: "戻す時もコントロール"),
                Template(machineId: "smith_machine", exerciseName: "スミスマシンスクワット", sets: 4, reps: 8, restSeconds: 120, cue: "太ももが床と平行まで下ろす"),
                Template(machineId: "dumbbells", exerciseName: "ダンベルランジ", sets: 3, reps: 10, restSeconds: 90, cue: "前足の踵で押し戻す"),
            ]
        case .shoulders:
            return [
                Template(machineId: "shoulder_press", exerciseName: "ショルダープレス", sets: 4, reps: 8, restSeconds: 90, cue: "肘は耳の少し前。肩のラインを意識"),
                Template(machineId: "dumbbells", exerciseName: "サイドレイズ", sets: 3, reps: 15, restSeconds: 60, cue: "小指側から持ち上げる"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルサイドレイズ", sets: 3, reps: 12, restSeconds: 60, cue: "肩を上げず三角筋で挙げる"),
                Template(machineId: "smith_machine", exerciseName: "スミスマシンショルダープレス", sets: 3, reps: 8, restSeconds: 90, cue: "前すぎず後ろすぎず、頭の真上"),
            ]
        case .arms:
            return [
                Template(machineId: "dumbbells", exerciseName: "ダンベルカール", sets: 3, reps: 12, restSeconds: 60, cue: "肘の位置を固定して上腕二頭筋に効かせる"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルトライセプスプッシュダウン", sets: 3, reps: 12, restSeconds: 60, cue: "肘は体側に固定して伸ばし切る"),
                Template(machineId: "bench_press", exerciseName: "クローズグリップベンチプレス", sets: 3, reps: 10, restSeconds: 90, cue: "肩幅より少し狭く握る"),
                Template(machineId: "pull_up_bar", exerciseName: "チンアップ", sets: 3, reps: 8, restSeconds: 90, cue: "順手より逆手で二頭筋に乗せる"),
            ]
        case .core:
            return [
                Template(machineId: "back_extension", exerciseName: "バックエクステンション", sets: 3, reps: 15, restSeconds: 60, cue: "脊柱起立筋にじわっと効かせる"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルクランチ", sets: 3, reps: 15, restSeconds: 60, cue: "腰ではなく腹で背中を丸める"),
            ]
        case .fullBody:
            return [
                Template(machineId: "treadmill", exerciseName: "トレッドミルウォームアップ", sets: 1, reps: 10, restSeconds: 0, cue: "10分。心拍を上げて関節を温める"),
                Template(machineId: "smith_machine", exerciseName: "スミスマシンスクワット", sets: 3, reps: 10, restSeconds: 120, cue: "下半身の大筋群から動かす"),
                Template(machineId: "lat_pulldown", exerciseName: "ラットプルダウン", sets: 3, reps: 10, restSeconds: 90, cue: "肘で引いて背中を使う"),
                Template(machineId: "chest_press", exerciseName: "チェストプレス", sets: 3, reps: 10, restSeconds: 90, cue: "胸の張りを保ったまま押す"),
                Template(machineId: "bike", exerciseName: "エアロバイクフィニッシュ", sets: 1, reps: 5, restSeconds: 0, cue: "5分。低強度で整える"),
            ]
        }
    }
}
