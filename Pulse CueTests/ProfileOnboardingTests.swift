//
//  ProfileOnboardingTests.swift
//  Pulse CueTests
//
//  The post-sign-in profile onboarding: when it is asked (server-confirmed
//  account, once per account, after guest adoption), what finishing writes
//  (the shared `UserProfile` and today's `DayLog` weight), and the V9 → V10
//  migration that adds its fields.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct ProfileOnboardingTests {

    private static let accountA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
    private static let accountB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!
    private static let noAnswers = GuestAdoptionConsent.Answers(workoutRaw: "", healthRaw: "")
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Fixture

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private static func authenticated(_ id: UUID, provider: String) -> ServerAccountState {
        .authenticated(ServerAccountProfile(
            user: .init(id: id.uuidString, state: "active", displayName: nil, createdAt: 0),
            linkedProviders: [.init(provider: provider, linkedAt: 0)],
            session: .init(expiresAt: 0)
        ))
    }

    private static func gate(
        _ state: ServerAccountState,
        _ scope: WorkoutDataScope,
        answers: GuestAdoptionConsent.Answers = noAnswers,
        _ context: ModelContext
    ) -> UUID? {
        ProfileOnboardingGate.accountNeedingOnboarding(state: state, scope: scope, answers: answers, in: context)
    }

    private static func validDraft() -> ProfileOnboardingDraft {
        var draft = ProfileOnboardingDraft(profile: nil, latestWeightKg: nil)
        draft.ageYears = 34
        draft.heightCm = 178
        draft.currentWeightText = "72.5"
        draft.biologicalSex = .male
        draft.trainingGoal = .strength
        draft.goalWeightText = "70"
        draft.trainingDaysPerWeek = 4
        draft.preferredSessionMinutes = 60
        draft.experienceLevel = .intermediate
        return draft
    }

    /// Finishes onboarding for `id` the way the screen does.
    private static func finish(_ id: UUID, _ context: ModelContext) throws {
        #expect(validDraft().apply(to: .account(id), modelContext: context, now: now) != nil)
        #expect(ProfileOnboardingDraft.markCompleted(scope: .account(id), modelContext: context, now: now))
        try context.save()
    }

    // MARK: - When it is asked

    @Test("Apple and Google first sign-ins both ask", arguments: ["apple", "google"])
    func firstSignInAsks(provider: String) throws {
        let context = ModelContext(try Self.makeContainer())
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: provider), .account(Self.accountA), context) == Self.accountA)
    }

    @Test("Not before the server confirms: guest, signing in, restoring, offline")
    func onlyServerConfirmedSessionsAsk() throws {
        let context = ModelContext(try Self.makeContainer())
        let states: [ServerAccountState] = [.guest, .unresolved, .restoring, .signingIn]
        for state in states {
            #expect(Self.gate(state, .account(Self.accountA), context) == nil)
        }
        // Offline launch: the scope is the last confirmed account, but this
        // launch has not been confirmed.
        #expect(Self.gate(.unreachable, .account(Self.accountA), context) == nil)
        // Authenticated, but the app is not (yet) showing that account.
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "apple"), .undetermined, context) == nil)
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "apple"), .account(Self.accountB), context) == nil)
    }

    @Test("Finished once: signing out and back in does not ask again; another account does")
    func askedOncePerAccount() throws {
        let context = ModelContext(try Self.makeContainer())
        try Self.finish(Self.accountA, context)

        #expect(Self.gate(.guest, .guest, context) == nil)
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "google"), .account(Self.accountA), context) == nil)
        #expect(Self.gate(Self.authenticated(Self.accountB, provider: "apple"), .account(Self.accountB), context) == Self.accountB)
    }

    @Test("An existing account profile without the marker is asked once, prefilled")
    func existingProfileIsAskedOnce() throws {
        let context = ModelContext(try Self.makeContainer())
        context.insert(UserProfile(heightCm: 160, ageYears: 41, goalWeightKg: 52, ownerAccountID: Self.accountA))
        try context.save()

        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "apple"), .account(Self.accountA), context) == Self.accountA)
        let draft = ProfileOnboardingDraft(
            profile: UserProfileStore.profile(for: .account(Self.accountA), modelContext: context),
            latestWeightKg: nil
        )
        #expect(draft.heightCm == 160)
        #expect(draft.ageYears == 41)
        #expect(draft.goalWeightKg == 52)
    }

    @Test("Deleting the account deletes the marker with its profile")
    func accountDeletionForgetsCompletion() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        try Self.finish(Self.accountA, context)

        let defaults = try #require(UserDefaults(suiteName: "profile-onboarding-\(UUID().uuidString)"))
        try AccountLocalDataCleanup(container: container, defaults: defaults).run(for: Self.accountA)

        let fresh = ModelContext(container)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: fresh) == nil)
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "apple"), .account(Self.accountA), fresh) == Self.accountA)
    }

    // MARK: - Guest adoption

    @Test("Waits for the adoption question, then onboards the profile adoption left")
    func waitsForGuestAdoption() throws {
        let context = ModelContext(try Self.makeContainer())
        context.insert(UserProfile(heightCm: 158, ageYears: 25, goalWeightKg: 50))
        context.insert(DayLog(date: DateUtils.startOfDay(Self.now), weightKg: 54))
        try context.save()
        let state = Self.authenticated(Self.accountA, provider: "apple")

        // The adoption question is pending: onboarding must not create an
        // account profile that would make the guest profile un-adoptable.
        let question = try #require(GuestAdoptionConsent.question(for: Self.accountA, answers: Self.noAnswers, in: context))
        #expect(question.profile)
        #expect(Self.gate(state, .account(Self.accountA), context) == nil)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context) == nil)

        var answers = Self.noAnswers
        try GuestAdoptionConsent.accept(question, answers: &answers, in: context)
        #expect(Self.gate(state, .account(Self.accountA), answers: answers, context) == Self.accountA)

        let adopted = UserProfileStore.profile(for: .account(Self.accountA), modelContext: context)
        #expect(adopted?.heightCm == 158)
        let draft = ProfileOnboardingDraft(
            profile: adopted,
            latestWeightKg: LatestBodyWeightResolver.latestWeightKg(scope: .account(Self.accountA), modelContext: context)
        )
        #expect(draft.heightCm == 158)
        #expect(draft.currentWeightKg == 54)
    }

    @Test("Declining adoption onboards a fresh account profile; the guest one stays guest")
    func declinedAdoptionKeepsGuestProfile() throws {
        let context = ModelContext(try Self.makeContainer())
        let guestProfile = UserProfile(heightCm: 158, ageYears: 25, goalWeightKg: 50)
        context.insert(guestProfile)
        context.insert(DayLog(date: DateUtils.startOfDay(Self.now), weightKg: 54))
        try context.save()

        let question = try #require(GuestAdoptionConsent.question(for: Self.accountA, answers: Self.noAnswers, in: context))
        let answers = Self.noAnswers.marking(question)
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "google"), .account(Self.accountA), answers: answers, context) == Self.accountA)

        try Self.finish(Self.accountA, context)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.id == guestProfile.id)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.heightCm == 158)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.profileOnboardingCompletedAt == nil)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context)?.heightCm == 178)
    }

    // MARK: - What finishing writes

    @Test("Answers land in the profile Settings edits and in today's day log")
    func answersShareSettingsSourceOfTruth() throws {
        let context = ModelContext(try Self.makeContainer())
        try Self.finish(Self.accountA, context)
        let scope = HealthDataScope.account(Self.accountA)

        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        #expect(profiles.count == 1)
        let profile = try #require(UserProfileStore.select(from: profiles, scope: scope))
        #expect(profile.ageYears == 34)
        #expect(profile.heightCm == 178)
        #expect(profile.biologicalSex == .male)
        #expect(profile.goalWeightKg == 70)
        #expect(profile.trainingGoal == .strength)
        #expect(profile.experienceLevel == .intermediate)
        #expect(profile.trainingDaysPerWeek == 4)
        #expect(profile.preferredSessionMinutes == 60)
        #expect(profile.profileOnboardingCompletedAt == Self.now)

        // The weight Settings and Home calculate from.
        #expect(LatestBodyWeightResolver.latestWeightKg(scope: scope, modelContext: context) == 72.5)
        #expect(BodyMetrics.resolveCurrentWeightKg(scope: scope, modelContext: context) == 72.5)
        #expect(DayLogStore.fetch(date: Self.now, scope: scope, modelContext: context)?.weightKg == 72.5)
        // Nothing written for anybody else.
        #expect(LatestBodyWeightResolver.latestWeightKg(scope: .guest, modelContext: context) == nil)
    }

    @Test("Incomplete or out-of-range answers write nothing")
    func validation() throws {
        let context = ModelContext(try Self.makeContainer())
        var noGoal = Self.validDraft()
        noGoal.trainingGoal = nil
        var noLevel = Self.validDraft()
        noLevel.experienceLevel = nil
        var heavy = Self.validDraft()
        heavy.currentWeightText = "400"
        var garbage = Self.validDraft()
        garbage.goalWeightText = "abc"
        for draft in [noGoal, noLevel, heavy, garbage] {
            #expect(draft.apply(to: .account(Self.accountA), modelContext: context) == nil)
        }
        #expect(Self.validDraft().apply(to: .undetermined, modelContext: context) == nil)
        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DayLog>()) == 0)

        #expect(ProfileOnboardingDraft.parse("65,5", in: ProfileOnboardingDraft.currentWeightRange) == 65.5)
        #expect(ProfileOnboardingDraft.parse("", in: ProfileOnboardingDraft.currentWeightRange) == nil)
    }

    @Test("An unknown raw value from a newer build reads as not set")
    func unknownRawValuesReadAsNil() {
        let profile = UserProfile()
        profile.trainingGoalRaw = "powerlifting"
        profile.experienceLevelRaw = "elite"
        #expect(profile.trainingGoal == nil)
        #expect(profile.experienceLevel == nil)
    }

    @Test("Every profile goal maps onto a plan generator goal")
    func profileGoalsBridgeToPlanGoals() {
        #expect(ProfileTrainingGoal.hypertrophy.planGoal == .hypertrophy)
        #expect(ProfileTrainingGoal.strength.planGoal == .strength)
        #expect(ProfileTrainingGoal.fatLoss.planGoal == .fatLoss)
        #expect(ProfileTrainingGoal.health.planGoal == .consistency)
        #expect(ProfileTrainingGoal.consistency.planGoal == .consistency)
    }

    // MARK: - Migration

    @Test("V10 is the latest schema and only swaps the pinned profile for the current one")
    func v10OnlyReplacesTheProfile() {
        let v9 = PulseCueSchemaV9.models.map { ObjectIdentifier($0) }
        let v10 = PulseCueSchemaV10.models.map { ObjectIdentifier($0) }
        #expect(v9.count == v10.count)
        #expect(Set(v10).subtracting(v9) == [ObjectIdentifier(UserProfile.self)])
        #expect(Set(v9).subtracting(v10) == [ObjectIdentifier(PulseCueSchemaV8.UserProfile.self)])
        #expect(PulseCueMigrationPlan.schemas.last == PulseCueSchemaV10.self)

        let v9Names = Set(Schema(versionedSchema: PulseCueSchemaV9.self).entitiesByName["UserProfile"]?.properties.map(\.name) ?? [])
        #expect(v9Names.contains("ownerAccountID"))
        #expect(!v9Names.contains("profileOnboardingCompletedAt"))
    }

    @Test("A V9 store's profiles open at V10 with their values and no onboarding marker")
    func v9StoreMigratesToV10() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v10migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let updated = Date(timeIntervalSinceReferenceDate: 800_020_000)

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV9.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(PulseCueSchemaV8.UserProfile(
                heightCm: 165, ageYears: 30, biologicalSexRaw: "female", activityFactorRaw: "moderate",
                goalWeightKg: 55, weeklyChangeKg: -0.25, updatedAt: updated, ownerAccountID: Self.accountA
            ))
            context.insert(PulseCueSchemaV8.UserProfile(
                heightCm: 180, ageYears: 40, biologicalSexRaw: "male", activityFactorRaw: "light",
                goalWeightKg: 80, weeklyChangeKg: 0, updatedAt: updated, ownerAccountID: nil
            ))
            try context.save()
        }

        let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        let account = try #require(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context))
        #expect(account.heightCm == 165)
        #expect(account.biologicalSex == .female)
        #expect(account.weeklyChangeKg == -0.25)
        #expect(account.updatedAt == updated)
        #expect(account.trainingGoal == nil)
        #expect(account.experienceLevel == nil)
        #expect(account.trainingDaysPerWeek == nil)
        #expect(account.preferredSessionMinutes == nil)
        #expect(account.profileOnboardingCompletedAt == nil)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.heightCm == 180)

        // Migrated, never onboarded: the account is asked once.
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "apple"), .account(Self.accountA), context) == Self.accountA)
    }
}
