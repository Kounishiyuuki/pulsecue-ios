//
//  WorkoutProgress.swift
//  Pulse Cue
//
//  Pure, read-only derivations for the Home / Progress experience, built from
//  the existing History source of truth (`Session` + `StepResult` + `Routine`
//  + `Step`). No new persisted model, no schema change, nothing writes. The
//  callers fetch the snapshots once (on screen appear / History change) and
//  hand them to these functions — never per body render.
//
//  Weight is not tracked anywhere, so every figure here is count / reps /
//  duration based. Nothing is invented (no calories, no "muscle growth").
//

import Foundation

// MARK: - Home / weekly summary

/// A compact "recent training" snapshot for Home: this calendar week's volume
/// plus the most recent completed workout (which also drives "repeat").
struct HomeProgressSummary: Equatable {
    struct LastWorkout: Equatable {
        let date: Date
        let routineId: UUID
        let routineName: String
        let durationSeconds: Int
    }

    let weeklyWorkoutCount: Int
    let weeklyTrainingDays: Int
    let weeklyCompletedSets: Int
    let weeklyDurationSeconds: Int
    let lastWorkout: LastWorkout?

    var hasHistory: Bool { lastWorkout != nil }

    static let empty = HomeProgressSummary(
        weeklyWorkoutCount: 0, weeklyTrainingDays: 0, weeklyCompletedSets: 0,
        weeklyDurationSeconds: 0, lastWorkout: nil
    )

    /// Only `completed` sessions count as workouts. "This week" is the calendar
    /// week (`.weekOfYear`) containing `now`.
    /// A value that changes whenever this summary would.
    ///
    /// The screens observed `sessions.count` and `stepResults.count`, and the
    /// event that matters most changes neither: finishing a workout flips an
    /// existing `Session` to `.completed` and writes its duration, and marking
    /// a set done flips an existing `StepResult`. Both leave the arrays the
    /// same length, so Home and Training went on showing the previous workout
    /// as the last one and last week's totals as this week's.
    ///
    /// Hashed rather than rendered to a string: this is read on every body
    /// evaluation, and the fields below are exactly the ones `make` reads —
    /// no more, so an unrelated edit does not force a recompute.
    static func changeSignature(
        sessions: [Session],
        results: [StepResult]
    ) -> Int {
        var hasher = Hasher()
        for session in sessions {
            hasher.combine(session.id)
            hasher.combine(session.status)
            hasher.combine(session.startedAt)
            hasher.combine(session.totalSeconds)
            hasher.combine(session.routineId)
        }
        for result in results {
            hasher.combine(result.id)
            hasher.combine(result.done)
            hasher.combine(result.sessionId)
        }
        return hasher.finalize()
    }

    static func make(
        sessions: [Session],
        results: [StepResult],
        routines: [Routine],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> HomeProgressSummary {
        let completed = sessions.filter { $0.status == .completed }
        guard !completed.isEmpty else { return .empty }

        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let thisWeek = completed.filter { week?.contains($0.startedAt) ?? false }
        let weekSessionIds = Set(thisWeek.map(\.id))

        let days = Set(thisWeek.map { calendar.startOfDay(for: $0.startedAt) }).count
        let sets = results.filter { $0.done && weekSessionIds.contains($0.sessionId) }.count
        let duration = thisWeek.reduce(0) { $0 + $1.totalSeconds }

        // Most recent completed workout overall (id tie-break → deterministic).
        let last = completed.max {
            ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString)
        }
        let lastWorkout = last.map { session in
            LastWorkout(
                date: session.startedAt,
                routineId: session.routineId,
                routineName: routines.first { $0.id == session.routineId }?.name ?? "ワークアウト",
                durationSeconds: session.totalSeconds
            )
        }

        return HomeProgressSummary(
            weeklyWorkoutCount: thisWeek.count,
            weeklyTrainingDays: days,
            weeklyCompletedSets: sets,
            weeklyDurationSeconds: duration,
            lastWorkout: lastWorkout
        )
    }
}

// MARK: - Per-exercise progress

/// Recent progress for one exercise, matched by stable `exerciseId` (never
/// display name) — the same identity rule as `PreviousPerformanceQuery`.
struct ExerciseProgressInsight: Equatable, Identifiable {
    enum Trend: Equatable { case up, flat, down, unknown }

    let exerciseId: String
    let exerciseName: String
    /// Completed-set reps of the most recent session, in set order.
    let latestReps: [Int]
    /// The session before that, if any.
    let previousReps: [Int]?
    /// Best single completed set ever (a truthful reps-only personal best).
    let personalBestReps: Int

    var id: String { exerciseId }

    /// Best set of latest vs best set of previous.
    var trend: Trend {
        guard let previous = previousReps, let last = latestReps.max(), let prev = previous.max() else {
            return previousReps == nil ? .unknown : .flat
        }
        if last > prev { return .up }
        if last < prev { return .down }
        return .flat
    }
}

enum WorkoutProgressQuery {

    /// Per-exercise insights, most-recently-trained first, limited to `limit`.
    /// Only completed sets with a rep count are used; exercises with no
    /// resolvable id (custom machines) are skipped. Deterministic.
    static func exerciseInsights(
        steps: [Step],
        sessions: [Session],
        results: [StepResult],
        limit: Int = 5
    ) -> [ExerciseProgressInsight] {
        let completed = Set(sessions.filter { $0.status == .completed }.map(\.id))
        let startedAt = Dictionary(sessions.map { ($0.id, $0.startedAt) }, uniquingKeysWith: { first, _ in first })

        // stepId → exerciseId, and exerciseId → a display name (latest step wins
        // is unnecessary; any step's title works).
        var exerciseIdByStep: [UUID: String] = [:]
        var nameByExercise: [String: String] = [:]
        for step in steps {
            guard let exerciseId = step.exerciseId else { continue }
            exerciseIdByStep[step.id] = exerciseId
            if nameByExercise[exerciseId] == nil { nameByExercise[exerciseId] = step.title }
        }

        // exerciseId → [sessionId: [setIndex-ordered reps]]
        struct Agg { var bySession: [UUID: [(set: Int, reps: Int)]] = [:]; var best = 0; var lastActivity = Date.distantPast }
        var byExercise: [String: Agg] = [:]

        for result in results {
            guard result.done, let reps = result.actualReps,
                  completed.contains(result.sessionId),
                  let exerciseId = exerciseIdByStep[result.stepId] else { continue }
            var agg = byExercise[exerciseId] ?? Agg()
            agg.bySession[result.sessionId, default: []].append((result.setIndex, reps))
            agg.best = max(agg.best, reps)
            agg.lastActivity = max(agg.lastActivity, startedAt[result.sessionId] ?? .distantPast)
            byExercise[exerciseId] = agg
        }

        let insights: [ExerciseProgressInsight] = byExercise.compactMap { exerciseId, agg in
            // Sessions for this exercise, newest first (date, then id tie-break).
            let orderedSessions = agg.bySession.keys.sorted { lhs, rhs in
                let l = startedAt[lhs] ?? .distantPast
                let r = startedAt[rhs] ?? .distantPast
                if l != r { return l > r }
                return lhs.uuidString > rhs.uuidString
            }
            guard let latestId = orderedSessions.first else { return nil }
            let latest = agg.bySession[latestId]!.sorted { $0.set < $1.set }.map(\.reps)
            let previous = orderedSessions.dropFirst().first.map { agg.bySession[$0]!.sorted { $0.set < $1.set }.map(\.reps) }
            return ExerciseProgressInsight(
                exerciseId: exerciseId,
                exerciseName: nameByExercise[exerciseId] ?? exerciseId,
                latestReps: latest,
                previousReps: previous,
                personalBestReps: agg.best
            )
        }

        // Most recently trained first; exercise id as a stable tie-break.
        return insights.sorted { lhs, rhs in
            let l = byExercise[lhs.exerciseId]?.lastActivity ?? .distantPast
            let r = byExercise[rhs.exerciseId]?.lastActivity ?? .distantPast
            if l != r { return l > r }
            return lhs.exerciseId < rhs.exerciseId
        }
        .prefix(limit)
        .map { $0 }
    }
}
