//
//  MachineExerciseTemplate.swift
//  Pulse Cue
//
//  Pure, value-only presentation helpers for the read-only machine
//  catalog detail screen (`MachineCatalogDetailView`). Intentionally:
//
//   - has no SwiftData / `@Model` dependency,
//   - performs no I/O — no networking, no persistence, no AI,
//   - derives its display strings solely from a `MachineCatalogEntry`.
//
//  Splitting this out of the view keeps the formatting logic unit
//  testable (see `MachineExerciseTemplateTests`) and avoids brittle UI
//  tests. It does NOT create or save a `Routine` — the "基本メニュー案"
//  section is a non-binding preview only.
//

import Foundation

/// Localized Japanese labels for the optional machine metadata enums.
/// Kept here as the single source of truth so both the list row and the
/// detail screen render identical text.
extension MachineCategory {
    var displayName: String {
        switch self {
        case .chest: return "胸"
        case .back: return "背中"
        case .shoulders: return "肩"
        case .arms: return "腕"
        case .legs: return "脚"
        case .core: return "体幹"
        case .cardio: return "有酸素"
        case .fullBody: return "全身"
        }
    }
}

extension EquipmentType {
    var displayName: String {
        switch self {
        case .machine: return "マシン"
        case .cable: return "ケーブル"
        case .freeWeight: return "フリーウェイト"
        case .bodyweight: return "自重"
        case .cardioMachine: return "有酸素マシン"
        }
    }
}

extension MovementPattern {
    var displayName: String {
        switch self {
        case .push: return "プッシュ"
        case .pull: return "プル"
        case .squat: return "スクワット"
        case .hinge: return "ヒンジ"
        case .lunge: return "ランジ"
        case .carry: return "キャリー"
        case .core: return "体幹"
        case .cardio: return "有酸素"
        }
    }
}

extension MachineDifficulty {
    var displayName: String {
        switch self {
        case .beginner: return "初級"
        case .intermediate: return "中級"
        case .advanced: return "上級"
        }
    }
}

/// A read-only "starter menu" preview derived from a catalog entry's
/// default sets / reps / rest. This is purely informational — it never
/// produces a `Routine`, `Step`, or any persisted data.
struct MachineExerciseTemplate: Equatable {
    let sets: Int?
    let reps: ClosedRange<Int>?
    let restSeconds: Int?

    init(sets: Int?, reps: ClosedRange<Int>?, restSeconds: Int?) {
        self.sets = sets
        self.reps = reps
        self.restSeconds = restSeconds
    }

    init(entry: MachineCatalogEntry) {
        self.init(
            sets: entry.defaultSets,
            reps: entry.defaultReps,
            restSeconds: entry.defaultRestSeconds
        )
    }

    /// True when the entry carries at least one usable default. When
    /// false the UI shows `Self.fallbackMessage` instead of a menu.
    var hasAnyDefault: Bool {
        sets != nil || reps != nil || restSeconds != nil
    }

    /// e.g. "3セット × 8〜12回", or "3セット" / "8〜12回" when only one
    /// of the two is present. `nil` when neither sets nor reps exist.
    var setsAndRepsText: String? {
        let setsText = sets.map { "\($0)セット" }
        let repsText = reps.map { range -> String in
            range.lowerBound == range.upperBound
                ? "\(range.lowerBound)回"
                : "\(range.lowerBound)〜\(range.upperBound)回"
        }
        switch (setsText, repsText) {
        case let (s?, r?): return "\(s) × \(r)"
        case let (s?, nil): return s
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    /// e.g. "セット間 90秒" / "セット間 1分30秒". `nil` when no rest is
    /// defined.
    var restText: String? {
        guard let restSeconds else { return nil }
        return "セット間 \(Self.humanizedDuration(seconds: restSeconds))"
    }

    /// Human-friendly Japanese duration: "45秒", "1分", "1分30秒".
    /// Negative input is clamped to 0.
    static func humanizedDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        let minutes = total / 60
        let remaining = total % 60
        if minutes == 0 { return "\(remaining)秒" }
        if remaining == 0 { return "\(minutes)分" }
        return "\(minutes)分\(remaining)秒"
    }

    /// Shown when an entry has no default menu yet. Generic, non-binding
    /// guidance — deliberately not tied to the specific machine.
    static let fallbackMessage =
        "このマシンの推奨メニューはまだ登録されていません。一般的な目安として、8〜12回 × 3セットを目安に、無理のない重さから始めてみましょう。"
}
