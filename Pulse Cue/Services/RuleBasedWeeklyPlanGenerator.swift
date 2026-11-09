//
//  RuleBasedWeeklyPlanGenerator.swift
//  Pulse Cue
//
//  v0 rule-based *weekly* plan generator. Given a user's goal/split and
//  the local `MachineCatalog`, it produces a multi-day plan made of
//  `RoutineStepCandidate` values — i.e. candidates only. Like
//  `WorkoutPlanGenerator` it is intentionally:
//
//   - pure and deterministic — no SwiftData, no `ModelContext`, no
//     clock, no RNG, so identical input always yields identical output,
//   - free of any networking / AI / external data,
//   - non-persisting — it never creates or saves `Routine`/`Step`; the
//     candidate → review → confirm → save boundary stays intact.
//
//  The current catalog is sparse (most entries only carry `bodyParts`),
//  so the rules deliberately lean on `bodyParts` and express goal /
//  experience through *exercise count and guidance copy* rather than
//  optional metadata that does not exist yet. See
//  `Docs/gym-machine-catalog-and-plan-foundation.md`.
//

import Foundation

// MARK: - Inputs

enum TrainingGoal: String, CaseIterable, Equatable, Sendable {
    case fatLoss, hypertrophy, strength, consistency

    var displayName: String {
        switch self {
        case .fatLoss: return "減量"
        case .hypertrophy: return "筋肥大"
        case .strength: return "筋力"
        case .consistency: return "習慣化"
        }
    }
}

enum ExperienceLevel: String, CaseIterable, Equatable, Sendable {
    case beginner, intermediate, advanced

    var displayName: String {
        switch self {
        case .beginner: return "初心者"
        case .intermediate: return "中級者"
        case .advanced: return "上級者"
        }
    }
}

enum TrainingSplit: String, CaseIterable, Equatable, Sendable {
    case fullBody, upperLower, pushPullLegs, bodyPart

    var displayName: String {
        switch self {
        case .fullBody: return "全身法"
        case .upperLower: return "上下分割"
        case .pushPullLegs: return "PPL"
        case .bodyPart: return "部位分割"
        }
    }
}

/// What each session leans toward when picking exercises. Independent of
/// `TrainingSplit` (the shape of the week): an upper/lower week can be
/// balanced or chest-focused. A theme only *re-orders* an already filtered
/// pool — it never removes equipment — so every safety filter still wins.
/// Scoring reads existing catalog metadata (`bodyParts`,
/// `secondaryMuscles`, `movementPattern`); there is no separate table.
enum SessionTheme: String, CaseIterable, Equatable, Sendable {
    case balanced, push, pull, press
    case chestFocus, backFocus, shoulderFocus, armsFocus, legsFocus, coreFocus

    var displayName: String {
        switch self {
        case .balanced: return "バランス"
        case .push: return "Push重視"
        case .pull: return "Pull重視"
        case .press: return "Press重視"
        case .chestFocus: return "胸重視"
        case .backFocus: return "背中重視"
        case .shoulderFocus: return "肩重視"
        case .armsFocus: return "腕重視"
        case .legsFocus: return "脚重視"
        case .coreFocus: return "体幹重視"
        }
    }

    /// The body part a `…Focus` theme favours.
    var focusBodyPart: BodyPart? {
        switch self {
        case .chestFocus: return .chest
        case .backFocus: return .back
        case .shoulderFocus: return .shoulders
        case .armsFocus: return .arms
        case .legsFocus: return .legs
        case .coreFocus: return .core
        case .balanced, .push, .pull, .press: return nil
        }
    }

    /// How strongly `equipment` fits this theme; 0 = not themed.
    ///
    /// - Body-part themes: a dedicated machine (few `bodyParts`) beats a
    ///   multi-purpose one; a secondary muscle counts a little.
    /// - Press: a multi-joint push (push pattern over 2+ body parts, e.g.
    ///   chest/shoulder presses) beats single-joint push work (pec deck,
    ///   lateral raise, calf raise, triceps extension).
    ///   This is an approximation from existing metadata, not a true
    ///   "compound press" flag: a general-purpose item tagged push over 2+
    ///   body parts (e.g. dumbbells) can also score 2.
    /// Custom equipment carries no movement pattern, so it only scores on
    /// body-part themes.
    func score(_ equipment: AvailableEquipment) -> Int {
        let pattern = equipment.catalogEntry?.movementPattern
        switch self {
        case .balanced:
            return 0
        case .push:
            return pattern == .push ? 1 : 0
        case .pull:
            return pattern == .pull ? 1 : 0
        case .press:
            guard pattern == .push else { return 0 }
            return equipment.bodyParts.count >= 2 ? 2 : 1
        case .chestFocus, .backFocus, .shoulderFocus, .armsFocus, .legsFocus, .coreFocus:
            guard let part = focusBodyPart else { return 0 }
            if equipment.bodyParts.contains(part) {
                return max(1, 4 - equipment.bodyParts.count)
            }
            return equipment.catalogEntry?.secondaryMuscles.contains(part) == true ? 1 : 0
        }
    }
}

/// All-optional-ish request describing what kind of week the user wants.
/// Defaulted so call sites and tests stay terse.
struct TrainingPlanGenerationRequest: Equatable {
    var goal: TrainingGoal
    var daysPerWeek: Int
    var targetBodyParts: [BodyPart]
    var limitedBodyParts: [BodyPart]
    var experienceLevel: ExperienceLevel
    var preferredSplit: TrainingSplit
    var sessionDurationMinutes: Int?
    var beginnerFriendlyOnly: Bool
    /// Defaults to `.balanced`, which reproduces the pre-theme selection
    /// exactly, so existing callers are unaffected.
    var sessionTheme: SessionTheme

    init(
        goal: TrainingGoal = .consistency,
        daysPerWeek: Int = 3,
        targetBodyParts: [BodyPart] = [],
        limitedBodyParts: [BodyPart] = [],
        experienceLevel: ExperienceLevel = .beginner,
        preferredSplit: TrainingSplit = .fullBody,
        sessionDurationMinutes: Int? = nil,
        beginnerFriendlyOnly: Bool = false,
        sessionTheme: SessionTheme = .balanced
    ) {
        self.goal = goal
        self.daysPerWeek = daysPerWeek
        self.targetBodyParts = targetBodyParts
        self.limitedBodyParts = limitedBodyParts
        self.experienceLevel = experienceLevel
        self.preferredSplit = preferredSplit
        self.sessionDurationMinutes = sessionDurationMinutes
        self.beginnerFriendlyOnly = beginnerFriendlyOnly
        self.sessionTheme = sessionTheme
    }
}

// MARK: - Outputs

/// One training day. `exercises` are candidates only — nothing here is
/// persisted or tied to a `ModelContext`.
struct TrainingSessionCandidate: Equatable {
    let title: String
    let focusBodyParts: [BodyPart]
    let exercises: [RoutineStepCandidate]
    let notes: String
}

struct WeeklyTrainingPlanCandidate: Equatable {
    let title: String
    let goal: TrainingGoal
    let daysPerWeek: Int
    let sessions: [TrainingSessionCandidate]
    /// Short human explanation of how the plan was shaped.
    let rationale: String
    /// Human-readable notes about clamps, relaxed filters, or thin
    /// catalog coverage.
    let warnings: [String]
    /// True when at least one session had more suitable equipment than it
    /// selected, i.e. a different `variationSeed` can yield a different
    /// plan. The review UI disables "別のプランを見る" when false.
    var hasAlternatives: Bool = false
    /// The theme the plan was generated with, so the review can show it.
    var sessionTheme: SessionTheme = .balanced

    /// True when no session managed to include any exercise (e.g. an
    /// empty catalog).
    var isEmpty: Bool { sessions.allSatisfy { $0.exercises.isEmpty } }

    /// Sessions that would become a `Routine` on save — those with at
    /// least one exercise. Pure derivation over `sessions`; constructs no
    /// `Routine`/`Step`. Mirrors the filter in
    /// `RoutineFactory.makeRoutines(from:)` so the review UI can show an
    /// accurate count without building transient model objects.
    var savableSessions: [TrainingSessionCandidate] {
        sessions.filter { !$0.exercises.isEmpty }
    }

    /// Number of routines a save would create.
    var savableSessionCount: Int { savableSessions.count }
}

// MARK: - Generator

enum RuleBasedWeeklyPlanGenerator {

    static let minDays = 1
    static let maxDays = 6
    static let maxExercisesPerSession = 6
    static let sourceLabel = "週間プラン"

    /// Balanced full-body coverage used when the user names no target
    /// parts. Excludes `.fullBody` (a catalog tag, not a training focus).
    static let balancedFullBody: [BodyPart] = [.chest, .back, .legs, .shoulders, .arms, .core]

    /// Generates a weekly candidate from unified available equipment.
    ///
    /// Defaults to the whole bundled catalog for generic planning when
    /// no gym is configured. Gym-aware callers must pass the active gym's
    /// available equipment from `GymRepository`, so unselected standard
    /// machines and unavailable custom machines cannot enter candidates.
    /// Unavailable equipment is dropped up front and never reaches a
    /// candidate.
    ///
    /// `variationSeed` picks one of several quality-equivalent plans. The
    /// same input + seed always yields the same plan; seed `0` (default)
    /// keeps catalog order. Filters (body parts, limits, beginner,
    /// equipment) run before the seed is applied, so no seed can break them.
    static func generate(
        request: TrainingPlanGenerationRequest,
        equipment: [AvailableEquipment] = AvailableEquipment.standardCatalog(),
        variationSeed: UInt64 = 0
    ) -> WeeklyTrainingPlanCandidate {
        let catalog = equipment.filter(\.isAvailable)
        var warnings: [String] = []
        func warn(_ message: String) {
            if !warnings.contains(message) { warnings.append(message) }
        }

        let days = clampedDays(request.daysPerWeek)
        if days != request.daysPerWeek {
            warn("週の日数を\(minDays)〜\(maxDays)日の範囲（\(days)日）に調整しました。")
        }

        let trainingSet = resolveTrainingSet(request: request, warn: warn)
        let perSession = exercisesPerSession(request)
        let daySpecs = daySpecs(split: request.preferredSplit, days: days, trainingSet: trainingSet)

        var sessions: [TrainingSessionCandidate] = []
        var anyFocusFallback = false
        var anyBeginnerRelaxed = false
        var anyShort = false
        var hasAlternatives = false
        var usedThisWeek: Set<String> = []
        var rng = SeededGenerator(seed: variationSeed)

        for (index, spec) in daySpecs.enumerated() {
            let selection = selectExercises(
                focus: spec.focus,
                catalog: catalog,
                count: perSession,
                beginnerOnly: request.beginnerFriendlyOnly,
                usedThisWeek: usedThisWeek,
                theme: request.sessionTheme,
                shuffle: variationSeed == 0 ? nil : { pool in pool.seededShuffled(using: &rng) }
            )
            usedThisWeek.formUnion(selection.equipmentIds)
            hasAlternatives = hasAlternatives || selection.hasAlternatives
            anyFocusFallback = anyFocusFallback || selection.focusFallback
            anyBeginnerRelaxed = anyBeginnerRelaxed || selection.beginnerRelaxed
            if !catalog.isEmpty && selection.candidates.count < perSession { anyShort = true }

            sessions.append(
                TrainingSessionCandidate(
                    title: "Day \(index + 1) · \(spec.label)",
                    focusBodyParts: spec.focus,
                    exercises: selection.candidates,
                    notes: sessionNotes(goal: request.goal)
                )
            )
        }

        if catalog.isEmpty {
            warn("マシンカタログが空のため、種目を提案できませんでした。")
        } else {
            if anyFocusFallback {
                warn("対象部位のマシンが見つからないセッションでは、全身から種目を選びました。")
            }
            if anyShort {
                warn("登録マシンが少ないため、一部のセッションは種目数が少なくなっています。")
            }
        }
        if anyBeginnerRelaxed {
            warn("初心者向けの情報がカタログに未登録のため、初心者向け条件を一部緩和しました。")
        }

        return WeeklyTrainingPlanCandidate(
            title: "\(request.goal.displayName)の週間プラン（\(request.preferredSplit.displayName)・週\(days)日）",
            goal: request.goal,
            daysPerWeek: days,
            sessions: sessions,
            rationale: rationale(request: request, days: days, perSession: perSession),
            warnings: warnings,
            hasAlternatives: hasAlternatives,
            sessionTheme: request.sessionTheme
        )
    }

    /// Upper bound on seeds tried by `nextDistinctVariation`. Neighbouring
    /// seeds can map to the same plan on small pools, so one step is not
    /// enough, but the search must stay bounded when no other plan exists.
    static let maxVariationAttempts = 32

    /// Walks seeds after `currentSeed` (deterministically, at most
    /// `maxAttempts`) and returns the first one whose plan differs from
    /// `current`. Returns nil when no different plan was found, so callers
    /// keep showing `current`. Pure: persists nothing.
    static func nextDistinctVariation(
        request: TrainingPlanGenerationRequest,
        equipment: [AvailableEquipment],
        current: WeeklyTrainingPlanCandidate,
        currentSeed: UInt64,
        maxAttempts: Int = maxVariationAttempts
    ) -> (seed: UInt64, candidate: WeeklyTrainingPlanCandidate)? {
        guard current.hasAlternatives else { return nil }
        var seed = currentSeed
        for _ in 0..<max(0, maxAttempts) {
            seed &+= 1
            let next = generate(request: request, equipment: equipment, variationSeed: seed)
            if next != current { return (seed, next) }
        }
        return nil
    }

    // MARK: - Training set

    /// Target parts (canonical order) or a balanced full body, with
    /// limited parts removed when that still leaves something to train.
    private static func resolveTrainingSet(
        request: TrainingPlanGenerationRequest,
        warn: (String) -> Void
    ) -> [BodyPart] {
        let target = canonical(request.targetBodyParts)
        let base = target.isEmpty ? balancedFullBody : target
        let limited = Set(request.limitedBodyParts)
        let filtered = base.filter { !limited.contains($0) }
        if filtered.isEmpty {
            warn("制限部位を除くと対象がなくなるため、制限を無視して対象部位を使用します。")
            return base
        }
        return filtered
    }

    // MARK: - Day focuses

    private static func daySpecs(
        split: TrainingSplit,
        days: Int,
        trainingSet: [BodyPart]
    ) -> [(focus: [BodyPart], label: String)] {
        guard !trainingSet.isEmpty else {
            return (0..<days).map { _ in ([], "全身") }
        }

        func cycle(_ specs: [(focus: [BodyPart], label: String)]) -> [(focus: [BodyPart], label: String)] {
            // Empty phases fall back to the whole training set so a day is
            // never focus-less, but keep their phase label for clarity.
            let normalized = specs.map { spec in
                spec.focus.isEmpty ? (trainingSet, spec.label) : spec
            }
            return (0..<days).map { normalized[$0 % normalized.count] }
        }

        switch split {
        case .fullBody:
            return (0..<days).map { _ in (trainingSet, "全身") }

        case .upperLower:
            return cycle([
                (intersect([.chest, .back, .shoulders, .arms], trainingSet), "上半身"),
                (intersect([.legs, .core], trainingSet), "下半身"),
            ])

        case .pushPullLegs:
            return cycle([
                (intersect([.chest, .shoulders, .arms], trainingSet), "プッシュ"),
                (intersect([.back, .arms], trainingSet), "プル"),
                (intersect([.legs, .core], trainingSet), "レッグ"),
            ])

        case .bodyPart:
            var buckets = Array(repeating: [BodyPart](), count: days)
            for (index, part) in trainingSet.enumerated() {
                buckets[index % days].append(part)
            }
            return buckets.enumerated().map { dayIndex, parts in
                let focus = parts.isEmpty ? [trainingSet[dayIndex % trainingSet.count]] : parts
                return (focus, focus.map(\.displayName).joined(separator: "/"))
            }
        }
    }

    // MARK: - Exercise selection

    private struct Selection {
        let candidates: [RoutineStepCandidate]
        let focusFallback: Bool
        let beginnerRelaxed: Bool
        /// The filtered pool held more equipment than was selected.
        let hasAlternatives: Bool
        var equipmentIds: [String] = []
    }

    private static func selectExercises(
        focus: [BodyPart],
        catalog: [AvailableEquipment],
        count: Int,
        beginnerOnly: Bool,
        usedThisWeek: Set<String>,
        theme: SessionTheme,
        shuffle: (([AvailableEquipment]) -> [AvailableEquipment])?
    ) -> Selection {
        guard !catalog.isEmpty, count > 0 else {
            return Selection(candidates: [], focusFallback: false, beginnerRelaxed: false, hasAlternatives: false)
        }

        func matches(parts: [BodyPart], beginner: Bool) -> [AvailableEquipment] {
            let query = MachineCatalogQuery(bodyParts: parts, beginnerFriendlyOnly: beginner)
            // Custom equipment has no `beginnerFriendly` flag, so a
            // beginner-only request excludes it conservatively rather
            // than assuming it is safe for beginners.
            return catalog.filter { $0.matches(query) }
        }

        var beginnerRelaxed = false
        var focusFallback = false

        var pool = matches(parts: focus, beginner: beginnerOnly)
        if pool.isEmpty && beginnerOnly {
            let relaxed = matches(parts: focus, beginner: false)
            if !relaxed.isEmpty {
                pool = relaxed
                beginnerRelaxed = true
            }
        }
        if pool.isEmpty {
            // No machine for this focus: widen to the whole catalog so the
            // session still has at least one exercise.
            focusFallback = true
            var whole = matches(parts: [], beginner: beginnerOnly)
            if whole.isEmpty {
                whole = catalog
                if beginnerOnly { beginnerRelaxed = true }
            }
            pool = whole
        }

        // The pool is already fully filtered, so reordering it cannot break
        // any constraint. Equipment not yet used this week goes first; used
        // equipment stays as a tail so a thin catalog still fills the day.
        let ordered = shuffle?(pool) ?? pool
        let fresh = ordered.filter { !usedThisWeek.contains($0.id) }
        let reused = ordered.filter { usedThisWeek.contains($0.id) }
        let chosen = themed(fresh: fresh, reused: reused, count: count, theme: theme)
        // Resolve each selected equipment into a concrete Exercise Library
        // movement using the day's focus (so a multi-purpose machine like
        // barbell/cable resolves to the right movement for this body part).
        // The selected equipment stays the hard boundary — resolution only
        // renames/identifies, it never widens the pool. Custom equipment has
        // no library movement, so it keeps the safe machine-name fallback.
        let resolutionParts = focus.isEmpty ? BodyPart.allCases : focus
        let candidates = chosen.map { equipment -> RoutineStepCandidate in
            let resolved = equipment.catalogEntry.flatMap {
                ExerciseLibrary.resolve(equipmentId: $0.id, bodyParts: resolutionParts)
            }
            return RoutineStepCandidate(
                equipment: equipment,
                resolvedExercise: resolved,
                sourceLabel: sourceLabel
            )
        }
        return Selection(
            candidates: candidates,
            focusFallback: focusFallback,
            beginnerRelaxed: beginnerRelaxed,
            hasAlternatives: pool.count > count,
            equipmentIds: chosen.map(\.id)
        )
    }

    /// Picks `count` items, favouring the theme without letting it take the
    /// whole session. Priority: hard constraints (already applied to the
    /// pool) > theme > unused this week > seeded order.
    /// - Themed slots (at most `themedSlots`): themed equipment by score,
    ///   fresh before reused only on equal score, so later sessions of the
    ///   week keep the theme even when the best fits were used on Day 1.
    /// - Remaining slots: fresh non-themed first (diversity), then whatever
    ///   is left, so a session never empties.
    /// `.balanced` is exactly the pre-theme rule. Ties keep the (possibly
    /// seeded) incoming order, so seeds still vary the plan within a theme.
    private static func themed(
        fresh: [AvailableEquipment],
        reused: [AvailableEquipment],
        count: Int,
        theme: SessionTheme
    ) -> [AvailableEquipment] {
        guard theme != .balanced else { return Array((fresh + reused).prefix(count)) }
        // Offset encodes "fresh before reused, then incoming order" as the
        // tie-break under the theme score.
        let ordered = fresh + reused
        let themedByScore = ordered.enumerated()
            .filter { theme.score($0.element) > 0 }
            .sorted { (theme.score($1.element), $0.offset) < (theme.score($0.element), $1.offset) }
            .map(\.element)
        var chosen = Array(themedByScore.prefix(themedSlots(count)))
        let picked = Set(chosen.map(\.id))
        let freshIds = Set(fresh.map(\.id))
        let leftover = ordered.filter { !picked.contains($0.id) }
        let rest = leftover.filter { freshIds.contains($0.id) && theme.score($0) == 0 }
            + leftover.filter { !(freshIds.contains($0.id) && theme.score($0) == 0) }
        chosen += rest.prefix(count - chosen.count)
        return chosen
    }

    /// Themed share of a session: all but a quarter (at least one kept for
    /// the base focus once there are 2+ exercises).
    static func themedSlots(_ count: Int) -> Int {
        count <= 1 ? count : count - max(1, count / 4)
    }

    // MARK: - Volume & copy rules

    private static func clampedDays(_ value: Int) -> Int {
        min(max(value, minDays), maxDays)
    }

    private static func exercisesPerSession(_ request: TrainingPlanGenerationRequest) -> Int {
        var count: Int
        switch request.experienceLevel {
        case .beginner: count = 3
        case .intermediate: count = 4
        case .advanced: count = 5
        }
        switch request.goal {
        case .consistency: count = min(count, 3)   // keep it light & repeatable
        case .strength: count = max(3, count - 1)  // fewer lifts, heavier focus
        case .fatLoss, .hypertrophy: break
        }
        if let minutes = request.sessionDurationMinutes {
            count = min(count, max(1, minutes / 12))
        }
        return min(max(count, 1), maxExercisesPerSession)
    }

    private static func sessionNotes(goal: TrainingGoal) -> String {
        switch goal {
        case .hypertrophy:
            return "中重量・中レップ（目安3セット×8〜12回）でボリュームを確保しましょう。"
        case .strength:
            return "高重量・低レップ（目安3〜5セット×3〜6回）でフォームを優先しましょう。"
        case .fatLoss:
            return "休憩は短めに、テンポよく進めましょう。"
        case .consistency:
            return "まずは習慣化を優先し、余裕を持って完了できる量にしています。"
        }
    }

    private static func rationale(
        request: TrainingPlanGenerationRequest,
        days: Int,
        perSession: Int
    ) -> String {
        "\(request.experienceLevel.displayName)向けに\(request.goal.displayName)を目的とした"
            + "\(request.preferredSplit.displayName)プランです（週\(days)日 / 1回あたり最大\(perSession)種目）。"
            + "カタログにセット数等が未登録の種目は、目安値"
            + "（約\(RoutineStepCandidate.fallbackSets)セット×\(RoutineStepCandidate.fallbackRepsTarget)レップ）として扱われます。"
            + (request.sessionTheme == .balanced ? "" : "セッションの方向性は「\(request.sessionTheme.displayName)」で、該当する種目を優先しています。")
    }

    // MARK: - Body-part helpers (deterministic ordering)

    /// De-duplicates and orders parts by the canonical `BodyPart.allCases`
    /// sequence so a `Set`/array in any order yields stable output.
    private static func canonical(_ parts: [BodyPart]) -> [BodyPart] {
        let wanted = Set(parts)
        return BodyPart.allCases.filter { wanted.contains($0) }
    }

    /// Intersection that preserves canonical order.
    private static func intersect(_ parts: [BodyPart], _ set: [BodyPart]) -> [BodyPart] {
        let allowed = Set(set)
        return canonical(parts).filter { allowed.contains($0) }
    }
}

// MARK: - Seeded variation

/// SplitMix64: a tiny, fully reproducible PRNG. Used instead of
/// `SystemRandomNumberGenerator` so the same `variationSeed` always yields
/// the same plan on every device and in unit tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Array {
    /// Fisher–Yates driven only by the supplied generator. Written out
    /// instead of `shuffled(using:)` because the stdlib does not promise a
    /// stable algorithm across Swift versions, which would silently change
    /// which plan a stored seed maps to.
    func seededShuffled(using generator: inout SeededGenerator) -> [Element] {
        var result = self
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            let j = Int(generator.next() % UInt64(i + 1))
            result.swapAt(i, j)
        }
        return result
    }
}
