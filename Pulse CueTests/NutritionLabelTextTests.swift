//
//  NutritionLabelTextTests.swift
//  Pulse CueTests
//
//  Parsing tests for the nutrition-label OCR prototype. They exercise
//  `NutritionLabelText` — the pure, Vision-free parser — against
//  fixture label strings. No live OCR and no network are involved;
//  the `NutritionLabelScanner` Vision step is intentionally not
//  unit-tested (it needs real images) and is covered manually.
//
//  Coverage:
//   - Japanese label with kcal + protein
//   - エネルギー / 熱量 / カロリー energy keywords
//   - たんぱく質 (hiragana) / タンパク質 (katakana) protein keywords
//   - decimal protein values
//   - missing protein / missing calories → nil
//   - malformed / non-numeric rows ignored safely
//   - multiple candidate lines pick the first reasonable value
//   - kcal preferred over a kJ figure on the same line
//   - full-width digits parsed
//   - unrelated rows (脂質 / 炭水化物 / 食塩相当量) ignored
//

import Testing
@testable import Pulse_Cue

struct NutritionLabelTextTests {

    // MARK: - Whole-label parsing

    @Test func parsesKcalAndProteinFromJapaneseLabel() {
        let candidate = NutritionLabelText.parse("""
        栄養成分表示（1食あたり）
        エネルギー 240kcal
        たんぱく質 9.2g
        脂質 12g
        炭水化物 22g
        食塩相当量 0.5g
        """)
        #expect(candidate.kcal == 240)
        #expect(candidate.proteinGrams == 9)
        #expect(candidate.isEmpty == false)
    }

    // MARK: - Energy keywords

    @Test func parsesEnergyKeyword() {
        let candidate = NutritionLabelText.parse("エネルギー：180 kcal")
        #expect(candidate.kcal == 180)
    }

    @Test func parsesHeatQuantityKeyword() {
        let candidate = NutritionLabelText.parse("熱量 320 kcal")
        #expect(candidate.kcal == 320)
    }

    @Test func parsesCalorieKeyword() {
        let candidate = NutritionLabelText.parse("カロリー 95kcal")
        #expect(candidate.kcal == 95)
    }

    @Test func parsesKcalUnitWithoutAnyKeyword() {
        // A bare "250kcal" row with no energy keyword still parses —
        // the unit alone is enough.
        let candidate = NutritionLabelText.parse("250kcal")
        #expect(candidate.kcal == 250)
    }

    // MARK: - Protein keywords

    @Test func parsesProteinHiraganaKeyword() {
        let candidate = NutritionLabelText.parse("たんぱく質 15g")
        #expect(candidate.proteinGrams == 15)
    }

    @Test func parsesProteinKatakanaKeyword() {
        let candidate = NutritionLabelText.parse("タンパク質 7g")
        #expect(candidate.proteinGrams == 7)
    }

    @Test func parsesDecimalProteinValue() {
        // 8.5 g rounds to a whole number — MealEntry.proteinGrams is Int.
        let candidate = NutritionLabelText.parse("たんぱく質 8.5g")
        #expect(candidate.proteinGrams == 9)
    }

    // MARK: - Missing values

    @Test func missingProteinReturnsNil() {
        let candidate = NutritionLabelText.parse("""
        エネルギー 200kcal
        脂質 5g
        炭水化物 30g
        """)
        #expect(candidate.kcal == 200)
        #expect(candidate.proteinGrams == nil)
    }

    @Test func missingCaloriesReturnsNil() {
        let candidate = NutritionLabelText.parse("""
        たんぱく質 10g
        脂質 5g
        """)
        #expect(candidate.kcal == nil)
        #expect(candidate.proteinGrams == 10)
    }

    // MARK: - Malformed / unrelated input

    @Test func malformedNumbersAreIgnoredSafely() {
        let candidate = NutritionLabelText.parse("""
        エネルギー ―kcal
        たんぱく質 ―g
        """)
        #expect(candidate.kcal == nil)
        #expect(candidate.proteinGrams == nil)
        #expect(candidate.isEmpty)
    }

    @Test func unrelatedRowsAreIgnored() {
        // Fat / carbohydrate / salt rows carry numbers but are not
        // energy or protein — they must never become candidates.
        let candidate = NutritionLabelText.parse("""
        脂質 12g
        炭水化物 45g
        食塩相当量 1.2g
        """)
        #expect(candidate.isEmpty)
    }

    @Test func emptyTextReturnsEmptyCandidate() {
        let candidate = NutritionLabelText.parse("")
        #expect(candidate.kcal == nil)
        #expect(candidate.proteinGrams == nil)
        #expect(candidate.isEmpty)
    }

    // MARK: - Disambiguation

    @Test func multipleEnergyLinesPickTheFirstReasonableValue() {
        // A label listing both a per-serving and a per-100 g column:
        // the per-serving figure is printed first and is taken.
        let candidate = NutritionLabelText.parse("""
        エネルギー 250kcal
        100gあたり エネルギー 480kcal
        たんぱく質 8g
        たんぱく質 16g
        """)
        #expect(candidate.kcal == 250)
        #expect(candidate.proteinGrams == 8)
    }

    @Test func prefersKcalOverKilojouleOnSameLine() {
        let candidate = NutritionLabelText.parse("エネルギー 1046kJ（250kcal）")
        #expect(candidate.kcal == 250)
    }

    @Test func parsesBothValuesFromASingleMergedLine() {
        // OCR sometimes merges a label row; protein is read from
        // after its keyword, so the kcal figure earlier on the line
        // is not mistaken for protein.
        let candidate = NutritionLabelText.parse("エネルギー 240kcal たんぱく質 9g")
        #expect(candidate.kcal == 240)
        #expect(candidate.proteinGrams == 9)
    }

    @Test func parsesFullWidthDigits() {
        let candidate = NutritionLabelText.parse("""
        エネルギー ２００kcal
        たんぱく質 １２g
        """)
        #expect(candidate.kcal == 200)
        #expect(candidate.proteinGrams == 12)
    }
}
