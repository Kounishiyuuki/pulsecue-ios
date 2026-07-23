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

    /// Conservative fallback prescription for a user-authored machine.
    /// We only know its name and body parts, so we do not pretend to know
    /// a precise prescription — these mirror `RoutineStepCandidate`'s
    /// fallbacks and the cue is generic, safety-oriented guidance.
    static let customFallbackSets = 3
    static let customFallbackReps = 10
    static let customFallbackRestSeconds = 60
    static let customFallbackCue = "重量とフォームを確認しながら、無理のない範囲で行う"

    /// Generates a plan from the gym's available equipment.
    ///
    /// Standard equipment keeps the original catalog-template behavior
    /// (same exercise names, sets, reps, rest and cues, same priority
    /// order). Custom equipment has no authored template, so a generic
    /// fallback exercise is derived from its display name and body parts
    /// and appended after the standard suggestions — custom machines
    /// supplement the catalog rather than displacing it.
    ///
    /// Unavailable equipment never enters a plan.
    static func generate(
        bodyPart: BodyPart,
        gym: Gym,
        availableEquipment: [AvailableEquipment]
    ) -> GeneratedPlan {
        let usable = availableEquipment.filter(\.isAvailable)
        let standardIds = Set(usable.filter { !$0.isCustom }.map(\.id))
        let templateMatches = templates(for: bodyPart).filter { standardIds.contains($0.machineId) }

        let standardExercises = templateMatches.map { template in
            GeneratedExercise(
                machineId: template.machineId,
                exerciseName: template.exerciseName,
                sets: template.sets,
                reps: template.reps,
                restSeconds: template.restSeconds,
                cue: template.cue
            )
        }

        // Custom machines qualify only when they actually train the
        // requested part. Deduped by reference id so one machine cannot
        // fill the plan twice.
        var seenCustomIds = Set<String>()
        let customExercises = usable
            .filter { $0.isCustom && $0.bodyParts.contains(bodyPart) }
            .compactMap { equipment -> GeneratedExercise? in
                guard seenCustomIds.insert(equipment.id).inserted else { return nil }
                return GeneratedExercise(
                    machineId: equipment.id,
                    exerciseName: equipment.displayName,
                    sets: customFallbackSets,
                    reps: customFallbackReps,
                    restSeconds: customFallbackRestSeconds,
                    cue: customFallbackCue
                )
            }

        let candidates = standardExercises + customExercises

        var warnings: [String] = []
        if usable.isEmpty {
            warnings.append("選択中のマシンがありません。マイジムから利用できるマシンを選択してください。")
        } else if candidates.isEmpty {
            warnings.append("\(bodyPart.displayName)を鍛えられるマシンが見つかりませんでした。別のマシンを追加するか、別の部位を選んでください。")
        } else if candidates.count < minMachinesForFullPlan {
            warnings.append("選択中のマシンが少ないためメニューが短くなっています。マシンを追加するとより良い提案ができます。")
        }

        return GeneratedPlan(
            bodyPart: bodyPart,
            gymId: gym.id,
            gymName: gym.name,
            exercises: Array(candidates.prefix(maxExercises)),
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

    #if DEBUG
    /// Test-only hook: the set of every machine id referenced by any
    /// body-part template. Lets catalog/template integrity tests assert
    /// "no template points at an unknown id" and "every new machine has a
    /// template" without exposing the private template table. Compiled out
    /// of Release builds.
    static var allTemplateMachineIds: Set<String> {
        Set(BodyPart.allCases.flatMap { templates(for: $0).map(\.machineId) })
    }
    #endif

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
                Template(machineId: "incline_chest_press", exerciseName: "インクラインチェストプレス", sets: 3, reps: 10, restSeconds: 90, cue: "胸の上部を意識して斜め上に押す"),
                Template(machineId: "barbell", exerciseName: "バーベルベンチプレス", sets: 4, reps: 8, restSeconds: 120, cue: "肩甲骨を寄せて胸でバーを受け止める"),
            ]
        case .back:
            return [
                Template(machineId: "lat_pulldown", exerciseName: "ラットプルダウン", sets: 4, reps: 10, restSeconds: 90, cue: "肘で引く意識。広背筋に効かせる"),
                Template(machineId: "seated_row", exerciseName: "シーテッドロー", sets: 3, reps: 10, restSeconds: 90, cue: "胸を張って肩甲骨を寄せる"),
                Template(machineId: "pull_up_bar", exerciseName: "プルアップ", sets: 3, reps: 8, restSeconds: 120, cue: "顎をバーまで。下ろす時もコントロール"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルロー", sets: 3, reps: 12, restSeconds: 75, cue: "ハンドルをみぞおちに引く"),
                Template(machineId: "back_extension", exerciseName: "バックエクステンション", sets: 3, reps: 12, restSeconds: 60, cue: "背中で起こす。反らしすぎ注意"),
                Template(machineId: "dumbbells", exerciseName: "ワンハンドダンベルロー", sets: 3, reps: 10, restSeconds: 75, cue: "脇腹に引き付けるイメージ"),
                Template(machineId: "assisted_pull_up", exerciseName: "アシストプルアップ", sets: 3, reps: 8, restSeconds: 90, cue: "補助に頼りすぎず背中で引き上げる"),
                Template(machineId: "barbell", exerciseName: "バーベルロー", sets: 4, reps: 8, restSeconds: 120, cue: "上体を倒し背中で引き上げる"),
            ]
        case .legs:
            return [
                Template(machineId: "leg_press", exerciseName: "レッグプレス", sets: 4, reps: 10, restSeconds: 120, cue: "膝はつま先と同じ向き"),
                Template(machineId: "leg_extension", exerciseName: "レッグエクステンション", sets: 3, reps: 12, restSeconds: 75, cue: "上で1秒キープして大腿四頭筋を絞る"),
                Template(machineId: "leg_curl", exerciseName: "レッグカール", sets: 3, reps: 12, restSeconds: 75, cue: "戻す時もコントロール"),
                Template(machineId: "smith_machine", exerciseName: "スミスマシンスクワット", sets: 4, reps: 8, restSeconds: 120, cue: "太ももが床と平行まで下ろす"),
                Template(machineId: "dumbbells", exerciseName: "ダンベルランジ", sets: 3, reps: 10, restSeconds: 90, cue: "前足の踵で押し戻す"),
                Template(machineId: "hack_squat", exerciseName: "ハックスクワット", sets: 4, reps: 10, restSeconds: 120, cue: "背中をパッドにつけて深く下ろす"),
                Template(machineId: "hip_abduction", exerciseName: "ヒップアブダクション", sets: 3, reps: 15, restSeconds: 45, cue: "外側に開いて中臀筋を意識する"),
                Template(machineId: "calf_raise", exerciseName: "カーフレイズ", sets: 4, reps: 15, restSeconds: 45, cue: "かかとを高く上げて母趾球で押す"),
                Template(machineId: "barbell", exerciseName: "バーベルスクワット", sets: 4, reps: 8, restSeconds: 150, cue: "太ももが床と平行まで下ろす"),
            ]
        case .shoulders:
            return [
                Template(machineId: "shoulder_press", exerciseName: "ショルダープレス", sets: 4, reps: 8, restSeconds: 90, cue: "肘は耳の少し前。肩のラインを意識"),
                Template(machineId: "dumbbells", exerciseName: "サイドレイズ", sets: 3, reps: 15, restSeconds: 60, cue: "小指側から持ち上げる"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルサイドレイズ", sets: 3, reps: 12, restSeconds: 60, cue: "肩を上げず三角筋で挙げる"),
                Template(machineId: "smith_machine", exerciseName: "スミスマシンショルダープレス", sets: 3, reps: 8, restSeconds: 90, cue: "前すぎず後ろすぎず、頭の真上"),
                Template(machineId: "lateral_raise_machine", exerciseName: "ラテラルレイズ", sets: 3, reps: 15, restSeconds: 45, cue: "肩の高さまで横に持ち上げる"),
                Template(machineId: "rear_delt_fly", exerciseName: "リアデルトフライ", sets: 3, reps: 15, restSeconds: 45, cue: "三角筋後部で腕を後ろに開く"),
                Template(machineId: "barbell", exerciseName: "バーベルショルダープレス", sets: 3, reps: 8, restSeconds: 90, cue: "頭の真上へ真っ直ぐ押し上げる"),
            ]
        case .arms:
            return [
                Template(machineId: "dumbbells", exerciseName: "ダンベルカール", sets: 3, reps: 12, restSeconds: 60, cue: "肘の位置を固定して上腕二頭筋に効かせる"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルトライセプスプッシュダウン", sets: 3, reps: 12, restSeconds: 60, cue: "肘は体側に固定して伸ばし切る"),
                Template(machineId: "bench_press", exerciseName: "クローズグリップベンチプレス", sets: 3, reps: 10, restSeconds: 90, cue: "肩幅より少し狭く握る"),
                Template(machineId: "pull_up_bar", exerciseName: "チンアップ", sets: 3, reps: 8, restSeconds: 90, cue: "順手より逆手で二頭筋に乗せる"),
                Template(machineId: "arm_curl_machine", exerciseName: "アームカール", sets: 3, reps: 12, restSeconds: 60, cue: "肘を固定して上腕二頭筋で挙げる"),
                Template(machineId: "triceps_extension_machine", exerciseName: "トライセプスエクステンション", sets: 3, reps: 12, restSeconds: 60, cue: "肘を固定して肘から先だけ伸ばす"),
                Template(machineId: "assisted_pull_up", exerciseName: "アシストチンアップ", sets: 3, reps: 8, restSeconds: 90, cue: "逆手で握り二頭筋に効かせる"),
                Template(machineId: "barbell", exerciseName: "バーベルカール", sets: 3, reps: 10, restSeconds: 75, cue: "反動を使わず二頭筋で挙げる"),
            ]
        case .core:
            return [
                Template(machineId: "back_extension", exerciseName: "バックエクステンション", sets: 3, reps: 15, restSeconds: 60, cue: "脊柱起立筋にじわっと効かせる"),
                Template(machineId: "cable_machine", exerciseName: "ケーブルクランチ", sets: 3, reps: 15, restSeconds: 60, cue: "腰ではなく腹で背中を丸める"),
                Template(machineId: "abdominal_machine", exerciseName: "アブドミナルクランチ", sets: 3, reps: 15, restSeconds: 45, cue: "背中を丸めて腹筋を収縮させる"),
            ]
        case .fullBody:
            return [
                Template(machineId: "treadmill", exerciseName: "トレッドミルウォームアップ", sets: 1, reps: 10, restSeconds: 0, cue: "10分。心拍を上げて関節を温める"),
                Template(machineId: "smith_machine", exerciseName: "スミスマシンスクワット", sets: 3, reps: 10, restSeconds: 120, cue: "下半身の大筋群から動かす"),
                Template(machineId: "lat_pulldown", exerciseName: "ラットプルダウン", sets: 3, reps: 10, restSeconds: 90, cue: "肘で引いて背中を使う"),
                Template(machineId: "chest_press", exerciseName: "チェストプレス", sets: 3, reps: 10, restSeconds: 90, cue: "胸の張りを保ったまま押す"),
                Template(machineId: "bike", exerciseName: "エアロバイクフィニッシュ", sets: 1, reps: 5, restSeconds: 0, cue: "5分。低強度で整える"),
                Template(machineId: "rowing_machine", exerciseName: "ローイングマシン", sets: 1, reps: 10, restSeconds: 0, cue: "5〜10分。全身で漕いで心拍を上げる"),
            ]
        }
    }
}
