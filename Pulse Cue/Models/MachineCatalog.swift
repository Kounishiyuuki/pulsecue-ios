//
//  MachineCatalog.swift
//  Pulse Cue
//
//  Canonical list of gym machines the app recognizes. Mirrors the
//  server-side catalog at `server/src/parser/machines.ts` for the
//  manual-selection MVP — they MUST stay in sync. A follow-up will
//  fetch this list from a `/api/machines/catalog` endpoint so iOS and
//  the server agree by construction; until then a unit test asserts
//  the local catalog id list is sorted and has no duplicates so any
//  drift shows up in a PR diff.
//
//  This file deliberately stays a value-only catalog. It does not
//  depend on SwiftData; persisted `GymMachine` rows denormalize the
//  display name at save time so renames here don't silently mutate
//  the user's saved data.
//

import Foundation

/// Coarse grouping used by future UI filters and the rule-based plan
/// generator. Mirrors `BodyPart` but kept as its own type so we can
/// evolve filtering (e.g. add `mobility`) without touching the persisted
/// `BodyPart` enum that already ships in saved data.
enum MachineCategory: String, Hashable, CaseIterable, Sendable {
    case chest, back, shoulders, arms, legs, core, cardio, fullBody
}

/// How the user interacts with the equipment. Useful for filtering when
/// a gym lacks certain gear, or when building beginner-friendly plans.
enum EquipmentType: String, Hashable, CaseIterable, Sendable {
    case machine, cable, freeWeight, bodyweight, cardioMachine
}

/// Primary movement pattern. Used by the future weekly plan generator
/// to balance push/pull and avoid stacking redundant patterns.
enum MovementPattern: String, Hashable, CaseIterable, Sendable {
    case push, pull, squat, hinge, lunge, carry, core, cardio
}

enum MachineDifficulty: String, Hashable, CaseIterable, Sendable {
    case beginner, intermediate, advanced
}

struct MachineCatalogEntry: Identifiable, Hashable {
    /// Canonical id matching the server catalog (e.g. `lat_pulldown`).
    let id: String
    /// User-facing Japanese label.
    let displayName: String
    /// Body parts this machine primarily trains. Used by the plan
    /// generator to filter candidate machines.
    let bodyParts: Set<BodyPart>

    // MARK: - Optional metadata (see Docs/gym-machine-catalog-and-plan-foundation.md §4)
    //
    // All fields below are optional / defaulted so existing catalog
    // entries compile unchanged and can be enriched gradually in later
    // PRs without breaking call sites.

    /// Primary category, typically the representative member of `bodyParts`.
    let category: MachineCategory?
    let equipmentType: EquipmentType?
    let movementPattern: MovementPattern?
    let difficulty: MachineDifficulty?
    let beginnerFriendly: Bool?
    /// Stable-ordered list of secondary muscle groups. Array (not Set)
    /// because catalog data is hand-written and we want diff-friendly
    /// ordering.
    let secondaryMuscles: [BodyPart]
    let setupNotes: String?
    let safetyNotes: String?
    let defaultSets: Int?
    /// Inclusive rep range the generator can sample from when it has no
    /// stronger signal. `nil` means "fall back to the generator's own
    /// template table".
    let defaultReps: ClosedRange<Int>?
    let defaultRestSeconds: Int?
    /// Free-form tags (e.g. "compound", "barbell"). Kept as an array so
    /// authoring order survives in PR diffs.
    let tags: [String]

    init(
        id: String,
        displayName: String,
        bodyParts: Set<BodyPart>,
        category: MachineCategory? = nil,
        equipmentType: EquipmentType? = nil,
        movementPattern: MovementPattern? = nil,
        difficulty: MachineDifficulty? = nil,
        beginnerFriendly: Bool? = nil,
        secondaryMuscles: [BodyPart] = [],
        setupNotes: String? = nil,
        safetyNotes: String? = nil,
        defaultSets: Int? = nil,
        defaultReps: ClosedRange<Int>? = nil,
        defaultRestSeconds: Int? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.bodyParts = bodyParts
        self.category = category
        self.equipmentType = equipmentType
        self.movementPattern = movementPattern
        self.difficulty = difficulty
        self.beginnerFriendly = beginnerFriendly
        self.secondaryMuscles = secondaryMuscles
        self.setupNotes = setupNotes
        self.safetyNotes = safetyNotes
        self.defaultSets = defaultSets
        self.defaultReps = defaultReps
        self.defaultRestSeconds = defaultRestSeconds
        self.tags = tags
    }
}

enum MachineCatalog {
    /// All known machines, sorted by `id` to keep PR diffs stable and
    /// to make the "no duplicate ids" test trivial.
    ///
    /// Every published entry carries the minimal metadata set the app
    /// relies on for filtering and guidance — `equipmentType`,
    /// `movementPattern`, `difficulty`, `beginnerFriendly`, and Japanese
    /// search `tags`. `BodyPart` stays coarse (7 cases), so muscle
    /// nuances (二頭/三頭・臀部・ふくらはぎ など) and common alias spellings
    /// live in `tags` rather than in new enum cases. Optional fields left
    /// unset here (`category`, `secondaryMuscles`, `defaultSets/Reps/Rest`,
    /// setup/safety notes) intentionally fall back to safe nil/empty.
    static let all: [MachineCatalogEntry] = [
        MachineCatalogEntry(id: "abdominal_machine", displayName: "腹筋マシン", bodyParts: [.core], equipmentType: .machine, movementPattern: .core, difficulty: .beginner, beginnerFriendly: true, tags: ["アブドミナル", "アブクランチ", "腹筋", "体幹"]),
        MachineCatalogEntry(id: "arm_curl_machine", displayName: "アームカールマシン", bodyParts: [.arms], equipmentType: .machine, movementPattern: .pull, difficulty: .beginner, beginnerFriendly: true, tags: ["アームカール", "バイセプス", "二頭", "上腕二頭筋"]),
        MachineCatalogEntry(id: "assisted_pull_up", displayName: "アシストプルアップ", bodyParts: [.back, .arms], equipmentType: .machine, movementPattern: .pull, difficulty: .beginner, beginnerFriendly: true, tags: ["アシストチンニング", "懸垂補助", "チンニング", "背中"]),
        MachineCatalogEntry(id: "back_extension", displayName: "バックエクステンション", bodyParts: [.back, .core], equipmentType: .machine, movementPattern: .hinge, difficulty: .beginner, beginnerFriendly: true, tags: ["バックエクステンション", "背筋", "脊柱起立筋", "腰"]),
        MachineCatalogEntry(id: "barbell", displayName: "バーベル", bodyParts: [.chest, .back, .legs, .shoulders, .arms], equipmentType: .freeWeight, movementPattern: .squat, difficulty: .advanced, beginnerFriendly: false, tags: ["フリーウェイト", "ベンチプレス", "スクワット", "デッドリフト"]),
        MachineCatalogEntry(id: "bench_press", displayName: "ベンチプレス", bodyParts: [.chest, .arms], equipmentType: .freeWeight, movementPattern: .push, difficulty: .intermediate, beginnerFriendly: false, tags: ["ベンチプレス", "大胸筋", "胸", "バーベル"]),
        MachineCatalogEntry(id: "bike", displayName: "エアロバイク", bodyParts: [.fullBody, .legs], equipmentType: .cardioMachine, movementPattern: .cardio, difficulty: .beginner, beginnerFriendly: true, tags: ["エアロバイク", "フィットネスバイク", "バイク", "有酸素"]),
        MachineCatalogEntry(id: "cable_machine", displayName: "ケーブルマシン", bodyParts: [.back, .chest, .arms, .shoulders], equipmentType: .cable, movementPattern: .pull, difficulty: .intermediate, beginnerFriendly: false, tags: ["ケーブル", "ケーブルマシン", "クロスオーバー", "ケーブルクロス"]),
        MachineCatalogEntry(id: "calf_raise", displayName: "カーフレイズマシン", bodyParts: [.legs], equipmentType: .machine, movementPattern: .push, difficulty: .beginner, beginnerFriendly: true, tags: ["カーフレイズ", "ふくらはぎ", "下腿", "カーフ"]),
        MachineCatalogEntry(id: "chest_press", displayName: "チェストプレス", bodyParts: [.chest, .arms], equipmentType: .machine, movementPattern: .push, difficulty: .beginner, beginnerFriendly: true, tags: ["チェストプレス", "胸プレス", "大胸筋", "胸"]),
        MachineCatalogEntry(id: "dumbbells", displayName: "ダンベル", bodyParts: [.chest, .back, .shoulders, .arms], equipmentType: .freeWeight, movementPattern: .push, difficulty: .intermediate, beginnerFriendly: false, tags: ["ダンベル", "フリーウェイト", "ダンベルプレス", "ダンベルカール"]),
        MachineCatalogEntry(id: "hack_squat", displayName: "ハックスクワット", bodyParts: [.legs], equipmentType: .machine, movementPattern: .squat, difficulty: .intermediate, beginnerFriendly: false, tags: ["ハックスクワットマシン", "スクワット", "大腿四頭筋", "脚"]),
        MachineCatalogEntry(id: "hip_abduction", displayName: "ヒップアブダクション", bodyParts: [.legs], equipmentType: .machine, movementPattern: .hinge, difficulty: .beginner, beginnerFriendly: true, tags: ["アブダクター", "外転", "お尻", "臀部", "中臀筋"]),
        MachineCatalogEntry(id: "incline_chest_press", displayName: "インクラインチェストプレス", bodyParts: [.chest, .arms], equipmentType: .machine, movementPattern: .push, difficulty: .beginner, beginnerFriendly: true, tags: ["インクラインプレス", "上部胸筋", "胸上部", "胸プレス"]),
        MachineCatalogEntry(id: "lat_pulldown", displayName: "ラットプルダウン", bodyParts: [.back, .arms], equipmentType: .machine, movementPattern: .pull, difficulty: .beginner, beginnerFriendly: true, tags: ["ラットプルダウン", "ラットプル", "広背筋", "背中"]),
        MachineCatalogEntry(id: "lateral_raise_machine", displayName: "ラテラルレイズマシン", bodyParts: [.shoulders], equipmentType: .machine, movementPattern: .push, difficulty: .beginner, beginnerFriendly: true, tags: ["サイドレイズ", "ラテラルレイズ", "肩横", "三角筋中部"]),
        MachineCatalogEntry(id: "leg_curl", displayName: "レッグカール", bodyParts: [.legs], equipmentType: .machine, movementPattern: .hinge, difficulty: .beginner, beginnerFriendly: true, tags: ["レッグカール", "ハムストリング", "もも裏", "脚"]),
        MachineCatalogEntry(id: "leg_extension", displayName: "レッグエクステンション", bodyParts: [.legs], equipmentType: .machine, movementPattern: .squat, difficulty: .beginner, beginnerFriendly: true, tags: ["レッグエクステンション", "大腿四頭筋", "もも前", "脚"]),
        MachineCatalogEntry(id: "leg_press", displayName: "レッグプレス", bodyParts: [.legs], equipmentType: .machine, movementPattern: .squat, difficulty: .beginner, beginnerFriendly: true, tags: ["レッグプレス", "大腿四頭筋", "脚", "下半身"]),
        MachineCatalogEntry(id: "pec_deck", displayName: "ペックデック", bodyParts: [.chest], equipmentType: .machine, movementPattern: .push, difficulty: .beginner, beginnerFriendly: true, tags: ["ペックデック", "ペックフライ", "大胸筋", "胸"]),
        MachineCatalogEntry(id: "pull_up_bar", displayName: "プルアップバー", bodyParts: [.back, .arms], equipmentType: .bodyweight, movementPattern: .pull, difficulty: .advanced, beginnerFriendly: false, tags: ["プルアップ", "懸垂", "チンニング", "背中"]),
        MachineCatalogEntry(id: "rear_delt_fly", displayName: "リアデルトフライ", bodyParts: [.shoulders, .back], equipmentType: .machine, movementPattern: .pull, difficulty: .beginner, beginnerFriendly: true, tags: ["リアデルト", "リバースフライ", "三角筋後部", "肩後部"]),
        MachineCatalogEntry(id: "rowing_machine", displayName: "ローイングマシン", bodyParts: [.fullBody, .back, .legs], equipmentType: .cardioMachine, movementPattern: .cardio, difficulty: .beginner, beginnerFriendly: true, tags: ["ローイングエルゴ", "ローワー", "有酸素", "ボート", "エルゴメーター"]),
        MachineCatalogEntry(id: "seated_row", displayName: "シーテッドロー", bodyParts: [.back, .arms], equipmentType: .machine, movementPattern: .pull, difficulty: .beginner, beginnerFriendly: true, tags: ["シーテッドロー", "ローイング", "広背筋", "背中"]),
        MachineCatalogEntry(id: "shoulder_press", displayName: "ショルダープレス", bodyParts: [.shoulders, .arms], equipmentType: .machine, movementPattern: .push, difficulty: .beginner, beginnerFriendly: true, tags: ["ショルダープレス", "三角筋", "肩", "オーバーヘッドプレス"]),
        MachineCatalogEntry(id: "smith_machine", displayName: "スミスマシン", bodyParts: [.chest, .legs, .shoulders], equipmentType: .machine, movementPattern: .squat, difficulty: .intermediate, beginnerFriendly: false, tags: ["スミスマシン", "スクワット", "ベンチプレス", "ガイド付き"]),
        MachineCatalogEntry(id: "treadmill", displayName: "トレッドミル", bodyParts: [.fullBody, .legs], equipmentType: .cardioMachine, movementPattern: .cardio, difficulty: .beginner, beginnerFriendly: true, tags: ["トレッドミル", "ランニングマシン", "有酸素", "ウォーキング"]),
        MachineCatalogEntry(id: "triceps_extension_machine", displayName: "トライセプスエクステンション", bodyParts: [.arms], equipmentType: .machine, movementPattern: .push, difficulty: .beginner, beginnerFriendly: true, tags: ["トライセプス", "三頭", "上腕三頭筋", "アームエクステンション"]),
    ]

    /// O(1) lookup by canonical id. Returns nil for ids that aren't in
    /// the catalog (e.g. older saved rows after a catalog rename).
    static func entry(for machineId: String) -> MachineCatalogEntry? {
        index[machineId]
    }

    /// Machines that train the given body part, in catalog order.
    static func entries(for bodyPart: BodyPart) -> [MachineCatalogEntry] {
        all.filter { $0.bodyParts.contains(bodyPart) }
    }

    private static let index: [String: MachineCatalogEntry] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()
}
