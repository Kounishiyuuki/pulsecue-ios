//
//  MealEntry.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Per-meal record used by NutritionView. SwiftData @Model so meals
//  are persisted alongside DayLog / Routine. Enums are stored as raw
//  Strings for forward-compatibility with light SwiftData migrations.
//
//  Status semantics (matches the AI privacy boundary in
//  AICoachStub.swift):
//  - .pending   : either a manual draft or an AI-suggested candidate
//                 that the user has NOT explicitly confirmed yet.
//                 AI entries always start here.
//  - .confirmed : user explicitly confirmed; counts toward
//                 DayLog.intakeCalories.
//

import Foundation
import SwiftData

@Model
final class MealEntry {
    @Attribute(.unique) var id: UUID
    /// Local-date the meal belongs to (startOfDay normalized).
    var dayDate: Date
    var slotRaw: String
    var name: String
    var kcal: Int
    var proteinGrams: Int?
    var carbGrams: Int?
    var fatGrams: Int?
    var statusRaw: String
    var sourceRaw: String
    var note: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        dayDate: Date,
        slot: MealSlot,
        name: String,
        kcal: Int,
        proteinGrams: Int? = nil,
        carbGrams: Int? = nil,
        fatGrams: Int? = nil,
        status: MealStatus,
        source: MealSource,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.dayDate = DateUtils.startOfDay(dayDate)
        self.slotRaw = slot.rawValue
        self.name = name.isEmpty ? slot.label : name
        self.kcal = max(0, kcal)
        self.proteinGrams = proteinGrams.map { max(0, $0) }
        self.carbGrams = carbGrams.map { max(0, $0) }
        self.fatGrams = fatGrams.map { max(0, $0) }
        self.statusRaw = status.rawValue
        self.sourceRaw = source.rawValue
        self.note = note
        self.createdAt = createdAt
    }

    var slot: MealSlot { MealSlot(rawValue: slotRaw) ?? .snack }
    var status: MealStatus { MealStatus(rawValue: statusRaw) ?? .pending }
    var source: MealSource { MealSource(rawValue: sourceRaw) ?? .manual }
}

// MARK: - Slots / status / source

enum MealSlot: String, CaseIterable, Identifiable, Codable {
    case breakfast
    case lunch
    case dinner
    case snack

    var id: String { rawValue }

    var label: String {
        switch self {
        case .breakfast: return "朝食"
        case .lunch: return "昼食"
        case .dinner: return "夕食"
        case .snack: return "間食"
        }
    }

    var enLabel: String {
        switch self {
        case .breakfast: return "BREAKFAST"
        case .lunch: return "LUNCH"
        case .dinner: return "DINNER"
        case .snack: return "SNACK"
        }
    }

    var sortOrder: Int {
        switch self {
        case .breakfast: return 0
        case .lunch: return 1
        case .dinner: return 2
        case .snack: return 3
        }
    }

    var systemImage: String {
        switch self {
        case .breakfast: return "sunrise.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .snack: return "cup.and.saucer.fill"
        }
    }

    var emptyPrompt: String {
        switch self {
        case .breakfast: return "朝食を記録する"
        case .lunch: return "昼食を記録する"
        case .dinner: return "夕食を記録する"
        case .snack: return "間食を記録する"
        }
    }
}

enum MealStatus: String, CaseIterable, Codable {
    case pending
    case confirmed

    var label: String {
        switch self {
        case .pending: return "確認待ち"
        case .confirmed: return "確定済み"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: return "hourglass"
        case .confirmed: return "checkmark.seal.fill"
        }
    }
}

enum MealSource: String, CaseIterable, Codable {
    case manual
    case ai

    var label: String {
        switch self {
        case .manual: return "手動"
        case .ai: return "AI 推定"
        }
    }
}
