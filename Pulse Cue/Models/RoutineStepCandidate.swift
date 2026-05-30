//
//  RoutineStepCandidate.swift
//  Pulse Cue
//
//  A local, read-only "what a routine step *could* look like" value
//  derived from a `MachineCatalogEntry`. This is the bridge between the
//  machine catalog and the eventual candidate → review → confirm → save
//  flow, but it deliberately stops at "candidate":
//
//   - it is a pure value type, NOT a SwiftData `@Model`,
//   - it never touches a `ModelContext`,
//   - it never creates a `Routine` or `Step`,
//   - it performs no I/O — no networking, no persistence, no AI.
//
//  It reuses `MachineExerciseTemplate` for sets/reps/rest formatting so
//  the candidate preview and the detail screen's "基本メニュー案" stay in
//  lockstep. The field shapes intentionally echo `GeneratedExercise` /
//  `Step` (machineId, exercise name, sets, reps, rest, note) so a later
//  PR can map a confirmed candidate onto those types without reshaping.
//

import Foundation

struct RoutineStepCandidate: Equatable {
    /// Canonical catalog id (e.g. `lat_pulldown`). Preserved so a future
    /// save step can re-resolve the source machine.
    let machineId: String
    /// User-facing exercise name — the machine's `displayName`.
    let exerciseName: String
    /// Primary body parts in canonical `BodyPart.allCases` order so the
    /// (unordered) source `Set` renders stably.
    let bodyParts: [BodyPart]
    /// Sets / reps / rest preview, reused from the detail screen so the
    /// numbers and fallback copy match exactly.
    let template: MachineExerciseTemplate
    /// Optional coaching note. Prefers the machine's setup guidance and
    /// falls back to its safety note; `nil` when the entry has neither.
    let notes: String?
    /// Where this candidate came from, surfaced in the preview so the
    /// user understands it is a suggestion, not a saved step.
    let sourceLabel: String

    init(
        machineId: String,
        exerciseName: String,
        bodyParts: [BodyPart],
        template: MachineExerciseTemplate,
        notes: String?,
        sourceLabel: String
    ) {
        self.machineId = machineId
        self.exerciseName = exerciseName
        self.bodyParts = bodyParts
        self.template = template
        self.notes = notes
        self.sourceLabel = sourceLabel
    }

    /// Builds a candidate from a catalog entry. This is the pure helper
    /// the preview uses — it allocates nothing persistent and is safe to
    /// call from any context. `sourceLabel` defaults to the catalog.
    init(entry: MachineCatalogEntry, sourceLabel: String = "マシンカタログ") {
        self.init(
            machineId: entry.id,
            exerciseName: entry.displayName,
            bodyParts: BodyPart.allCases.filter { entry.bodyParts.contains($0) },
            template: MachineExerciseTemplate(entry: entry),
            notes: entry.setupNotes ?? entry.safetyNotes,
            sourceLabel: sourceLabel
        )
    }

    /// True when the entry carried at least one usable default. When
    /// false the preview shows `MachineExerciseTemplate.fallbackMessage`.
    var hasMenuDefaults: Bool { template.hasAnyDefault }

    /// e.g. "3セット × 8〜12回" — `nil` when no sets/reps default exists.
    var setsAndRepsText: String? { template.setsAndRepsText }

    /// e.g. "セット間 1分30秒" — `nil` when no rest default exists.
    var restText: String? { template.restText }

    // MARK: - Save resolution
    //
    // The catalog template's sets / reps / rest are optional, but saving
    // as a `Step` needs concrete `Int`s. These accessors apply sensible
    // fallbacks so a routine can always be built from any candidate, and
    // `Step.init` clamps the results further. They produce plain values
    // only — no `Step`/`Routine` is created here.

    /// Set count used when no catalog default exists.
    static let fallbackSets = 3
    /// Target reps used when no catalog rep range exists.
    static let fallbackRepsTarget = 10
    /// Rest (seconds) used when no catalog default exists.
    static let fallbackRestSeconds = 60

    /// Concrete set count to save.
    var resolvedSets: Int { template.sets ?? Self.fallbackSets }

    /// Concrete target reps to save. Uses the *lower bound* of the
    /// catalog rep range — a conservative, reliably hittable target —
    /// or a generic fallback when no range is defined.
    var resolvedRepsTarget: Int { template.reps?.lowerBound ?? Self.fallbackRepsTarget }

    /// Concrete rest (seconds) to save.
    var resolvedRestSeconds: Int { template.restSeconds ?? Self.fallbackRestSeconds }
}
