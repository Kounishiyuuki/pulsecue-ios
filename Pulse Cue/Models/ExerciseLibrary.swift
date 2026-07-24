//
//  ExerciseLibrary.swift
//  Pulse Cue
//
//  The bundled catalog of standard *movements*. This is the single source
//  of stable exercise identity shared by the single-workout and weekly
//  planners. It is static Swift metadata — no SwiftData, no I/O, no
//  network, no startup indexing — small enough to iterate directly.
//
//  Every entry corresponds to an actual authored movement that already
//  existed in `WorkoutPlanGenerator`'s curated template table; this file
//  gives each one a stable `ExerciseID`. Movements sharing the same
//  authored name (e.g. バックエクステンション in both back and core days)
//  reuse one id; different movements on the same equipment (e.g. barbell
//  bench vs barbell row vs barbell squat) get distinct ids.
//
//  Authoring rules enforced by `ExerciseLibraryTests` (tests fail rather
//  than the app crashing on a mistake):
//   - ids unique and match `ExerciseID.formatPattern`,
//   - display names non-empty,
//   - every exact equipment id exists in `MachineCatalog`.
//
//  User-authored custom machines are NEVER represented here.
//

import Foundation

enum ExerciseLibrary {

    /// Canonical, order-stable movement list. The declaration order is the
    /// deterministic preference used by `resolve(equipmentId:bodyParts:)`,
    /// so barbell/dumbbell/cable/smith multi-purpose equipment maps to the
    /// right movement for a given body part without depending on dictionary
    /// iteration order.
    static let all: [Exercise] = [
        // MARK: Chest
        Exercise(id: "machine_chest_press", displayName: "チェストプレス",
                 aliases: ["chest press"], primaryBodyPart: .chest, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("chest_press")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "bench_press", displayName: "ベンチプレス",
                 primaryBodyPart: .chest, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("bench_press")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: false),
        Exercise(id: "dumbbell_bench_press", displayName: "ダンベルプレス",
                 primaryBodyPart: .chest, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("dumbbells")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: false),
        Exercise(id: "pec_deck_fly", displayName: "ペックフライ",
                 primaryBodyPart: .chest,
                 compatibleEquipment: [.machine("pec_deck")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "cable_crossover", displayName: "ケーブルクロスオーバー",
                 primaryBodyPart: .chest,
                 compatibleEquipment: [.machine("cable_machine")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: nil),
        Exercise(id: "smith_bench_press", displayName: "スミスマシンベンチプレス",
                 primaryBodyPart: .chest, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("smith_machine")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: nil),
        Exercise(id: "incline_chest_press", displayName: "インクラインチェストプレス",
                 primaryBodyPart: .chest, secondaryBodyParts: [.shoulders, .arms],
                 compatibleEquipment: [.machine("incline_chest_press")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "barbell_bench_press", displayName: "バーベルベンチプレス",
                 primaryBodyPart: .chest, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("barbell")], movementPattern: .push,
                 difficulty: .advanced, beginnerFriendly: false),

        // MARK: Back
        Exercise(id: "lat_pulldown", displayName: "ラットプルダウン",
                 aliases: ["lat pulldown"], primaryBodyPart: .back, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("lat_pulldown")], movementPattern: .pull,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "machine_seated_row", displayName: "シーテッドロー",
                 aliases: ["seated row"], primaryBodyPart: .back, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("seated_row")], movementPattern: .pull,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "pull_up", displayName: "プルアップ",
                 primaryBodyPart: .back, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("pull_up_bar")], movementPattern: .pull,
                 difficulty: .advanced, beginnerFriendly: false),
        Exercise(id: "cable_row", displayName: "ケーブルロー",
                 primaryBodyPart: .back, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("cable_machine")], movementPattern: .pull,
                 difficulty: .intermediate, beginnerFriendly: nil),
        Exercise(id: "back_extension", displayName: "バックエクステンション",
                 primaryBodyPart: .back, secondaryBodyParts: [.core],
                 compatibleEquipment: [.machine("back_extension")], movementPattern: .hinge,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "dumbbell_one_arm_row", displayName: "ワンハンドダンベルロー",
                 primaryBodyPart: .back, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("dumbbells")], movementPattern: .pull,
                 difficulty: .intermediate, beginnerFriendly: false),
        Exercise(id: "assisted_pull_up", displayName: "アシストプルアップ",
                 primaryBodyPart: .back, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("assisted_pull_up")], movementPattern: .pull,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "barbell_row", displayName: "バーベルロー",
                 primaryBodyPart: .back, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("barbell")], movementPattern: .pull,
                 difficulty: .advanced, beginnerFriendly: false),

        // MARK: Legs
        Exercise(id: "leg_press", displayName: "レッグプレス",
                 aliases: ["leg press"], primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("leg_press")], movementPattern: .squat,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "leg_extension", displayName: "レッグエクステンション",
                 aliases: ["leg extension"], primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("leg_extension")], movementPattern: .squat,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "leg_curl", displayName: "レッグカール",
                 aliases: ["leg curl"], primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("leg_curl")], movementPattern: .hinge,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "smith_squat", displayName: "スミスマシンスクワット",
                 primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("smith_machine")], movementPattern: .squat,
                 difficulty: .intermediate, beginnerFriendly: nil),
        Exercise(id: "dumbbell_lunge", displayName: "ダンベルランジ",
                 primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("dumbbells")], movementPattern: .lunge,
                 difficulty: .intermediate, beginnerFriendly: false),
        Exercise(id: "hack_squat", displayName: "ハックスクワット",
                 primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("hack_squat")], movementPattern: .squat,
                 difficulty: .intermediate, beginnerFriendly: nil),
        Exercise(id: "hip_abduction", displayName: "ヒップアブダクション",
                 primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("hip_abduction")], movementPattern: .hinge,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "calf_raise", displayName: "カーフレイズ",
                 primaryBodyPart: .legs,
                 compatibleEquipment: [.machine("calf_raise")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "barbell_back_squat", displayName: "バーベルスクワット",
                 aliases: ["back squat"], primaryBodyPart: .legs, secondaryBodyParts: [.core],
                 compatibleEquipment: [.machine("barbell")], movementPattern: .squat,
                 difficulty: .advanced, beginnerFriendly: false),

        // MARK: Shoulders
        Exercise(id: "machine_shoulder_press", displayName: "ショルダープレス",
                 aliases: ["shoulder press"], primaryBodyPart: .shoulders, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("shoulder_press")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "dumbbell_lateral_raise", displayName: "サイドレイズ",
                 primaryBodyPart: .shoulders,
                 compatibleEquipment: [.machine("dumbbells")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: false),
        Exercise(id: "cable_lateral_raise", displayName: "ケーブルサイドレイズ",
                 primaryBodyPart: .shoulders,
                 compatibleEquipment: [.machine("cable_machine")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: nil),
        Exercise(id: "smith_shoulder_press", displayName: "スミスマシンショルダープレス",
                 primaryBodyPart: .shoulders, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("smith_machine")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: nil),
        Exercise(id: "machine_lateral_raise", displayName: "ラテラルレイズ",
                 aliases: ["lateral raise"], primaryBodyPart: .shoulders,
                 compatibleEquipment: [.machine("lateral_raise_machine")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "rear_delt_fly", displayName: "リアデルトフライ",
                 primaryBodyPart: .shoulders, secondaryBodyParts: [.back],
                 compatibleEquipment: [.machine("rear_delt_fly")], movementPattern: .pull,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "barbell_shoulder_press", displayName: "バーベルショルダープレス",
                 aliases: ["overhead press"], primaryBodyPart: .shoulders, secondaryBodyParts: [.arms],
                 compatibleEquipment: [.machine("barbell")], movementPattern: .push,
                 difficulty: .advanced, beginnerFriendly: false),

        // MARK: Arms
        Exercise(id: "dumbbell_biceps_curl", displayName: "ダンベルカール",
                 primaryBodyPart: .arms,
                 compatibleEquipment: [.machine("dumbbells")], movementPattern: .pull,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "cable_triceps_pushdown", displayName: "ケーブルトライセプスプッシュダウン",
                 aliases: ["triceps pushdown"], primaryBodyPart: .arms,
                 compatibleEquipment: [.machine("cable_machine")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "close_grip_bench_press", displayName: "クローズグリップベンチプレス",
                 primaryBodyPart: .arms, secondaryBodyParts: [.chest],
                 compatibleEquipment: [.machine("bench_press")], movementPattern: .push,
                 difficulty: .intermediate, beginnerFriendly: false),
        Exercise(id: "chin_up", displayName: "チンアップ",
                 primaryBodyPart: .arms, secondaryBodyParts: [.back],
                 compatibleEquipment: [.machine("pull_up_bar")], movementPattern: .pull,
                 difficulty: .advanced, beginnerFriendly: false),
        Exercise(id: "machine_arm_curl", displayName: "アームカール",
                 aliases: ["arm curl"], primaryBodyPart: .arms,
                 compatibleEquipment: [.machine("arm_curl_machine")], movementPattern: .pull,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "machine_triceps_extension", displayName: "トライセプスエクステンション",
                 primaryBodyPart: .arms,
                 compatibleEquipment: [.machine("triceps_extension_machine")], movementPattern: .push,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "assisted_chin_up", displayName: "アシストチンアップ",
                 primaryBodyPart: .arms, secondaryBodyParts: [.back],
                 compatibleEquipment: [.machine("assisted_pull_up")], movementPattern: .pull,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "barbell_curl", displayName: "バーベルカール",
                 primaryBodyPart: .arms,
                 compatibleEquipment: [.machine("barbell")], movementPattern: .pull,
                 difficulty: .intermediate, beginnerFriendly: false),

        // MARK: Core
        Exercise(id: "cable_crunch", displayName: "ケーブルクランチ",
                 primaryBodyPart: .core,
                 compatibleEquipment: [.machine("cable_machine")], movementPattern: .core,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "machine_ab_crunch", displayName: "アブドミナルクランチ",
                 primaryBodyPart: .core,
                 compatibleEquipment: [.machine("abdominal_machine")], movementPattern: .core,
                 difficulty: .beginner, beginnerFriendly: true),

        // MARK: Full body / cardio
        Exercise(id: "treadmill_warmup", displayName: "トレッドミルウォームアップ",
                 primaryBodyPart: .fullBody, secondaryBodyParts: [.legs],
                 compatibleEquipment: [.machine("treadmill")], movementPattern: .cardio,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "bike_finisher", displayName: "エアロバイクフィニッシュ",
                 primaryBodyPart: .fullBody, secondaryBodyParts: [.legs],
                 compatibleEquipment: [.machine("bike")], movementPattern: .cardio,
                 difficulty: .beginner, beginnerFriendly: true),
        Exercise(id: "rowing_machine", displayName: "ローイングマシン",
                 primaryBodyPart: .fullBody, secondaryBodyParts: [.back, .legs],
                 compatibleEquipment: [.machine("rowing_machine")], movementPattern: .cardio,
                 difficulty: .beginner, beginnerFriendly: true),
    ]

    // MARK: - Indexes (built once)

    private static let byId: [ExerciseID: Exercise] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    // MARK: - Lookup / validation API
    //
    // These are also the surface a future AI plan validator uses: it must
    // resolve/validate stable ids, never fuzzy natural-language names.

    /// The movement for a stable id, or `nil` if unknown.
    static func exercise(for id: ExerciseID) -> Exercise? { byId[id] }

    /// Whether `id` is a real, well-formed library id. The future AI
    /// contract validates output against this — an allowlist, not a guess.
    static func isValid(_ id: ExerciseID) -> Bool { byId[id] != nil }

    /// All movements performable on a given exact catalog equipment id,
    /// in canonical library order.
    static func exercises(forEquipment equipmentId: String) -> [Exercise] {
        all.filter { $0.supports(machineId: equipmentId) }
    }

    /// Deterministically pick the movement for a piece of standard
    /// equipment given the requested body-part context.
    ///
    /// Preference order (all within canonical library order):
    ///   1. an exercise whose *primary* body part is one of `bodyParts`,
    ///      trying the parts in the given order,
    ///   2. otherwise an exercise that trains any of `bodyParts`,
    ///   3. otherwise the first exercise for this equipment.
    /// Returns `nil` only when no library movement uses this equipment
    /// (e.g. a custom machine, which has no `equipmentId` in the library).
    static func resolve(equipmentId: String, bodyParts: [BodyPart]) -> Exercise? {
        let supported = exercises(forEquipment: equipmentId)
        guard !supported.isEmpty else { return nil }

        for part in bodyParts {
            if let match = supported.first(where: { $0.primaryBodyPart == part }) {
                return match
            }
        }
        for part in bodyParts {
            if let match = supported.first(where: { $0.trains(part) }) {
                return match
            }
        }
        return supported.first
    }
}
