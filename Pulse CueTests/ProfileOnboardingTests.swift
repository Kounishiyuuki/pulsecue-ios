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
        draft.currentWeightKg = 72.5
        draft.biologicalSex = .male
        draft.activityFactor = .active
        draft.trainingGoal = .strength
        draft.goalWeightKg = 70
        draft.weeklyChangeKg = 0.2
        draft.trainingDaysPerWeek = 4
        draft.preferredSessionMinutes = 60
        draft.experienceLevel = .intermediate
        return draft
    }

    /// Finishes onboarding for `id` the way the screen does.
    private static func finish(_ id: UUID, _ context: ModelContext) throws {
        for step in ProfileOnboardingStep.allCases {
            #expect(validDraft().save(step, to: .account(id), modelContext: context, now: now) != nil)
            try context.save()
        }
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
        #expect(profile.activityFactor == .active)
        #expect(profile.goalWeightKg == 70)
        #expect(profile.weeklyChangeKg == 0.2)
        #expect(profile.trainingGoal == .strength)
        #expect(profile.experienceLevel == .intermediate)
        #expect(profile.trainingDaysPerWeek == 4)
        #expect(profile.preferredSessionMinutes == 60)
        #expect(profile.profileOnboardingCompletedAt == Self.now)
        #expect(profile.profileOnboardingStepRaw == nil)

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
        heavy.currentWeightKg = 400
        var garbage = Self.validDraft()
        garbage.goalWeightKg = nil
        var offGrid = Self.validDraft()
        offGrid.preferredSessionMinutes = 35
        var tooShort = Self.validDraft()
        tooShort.preferredSessionMinutes = 15
        let cases: [(ProfileOnboardingDraft, ProfileOnboardingStep)] = [
            (noGoal, .goal), (noLevel, .habits), (heavy, .basics), (garbage, .goal),
            (offGrid, .habits), (tooShort, .habits),
        ]
        for (draft, step) in cases {
            #expect(!draft.isValid(step))
            #expect(draft.save(step, to: .account(Self.accountA), modelContext: context) == nil)
        }
        #expect(Self.validDraft().save(.basics, to: .undetermined, modelContext: context) == nil)
        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DayLog>()) == 0)

    }

    // MARK: - Resuming

    @Test("Each step's answers and the resume point are stored on 次へ")
    func resumesAtTheFirstUnsavedStep() throws {
        let container = try Self.makeContainer()
        let scope = HealthDataScope.account(Self.accountA)
        let expected: [ProfileOnboardingStep: ProfileOnboardingStep] = [.basics: .goal, .goal: .habits, .habits: .done]
        for step in [ProfileOnboardingStep.basics, .goal, .habits] {
            let context = ModelContext(container)
            #expect(Self.validDraft().save(step, to: scope, modelContext: context, now: Self.now) != nil)
            try context.save()

            // A relaunch: a fresh context reads only what was committed.
            let fresh = ModelContext(container)
            let profile = try #require(UserProfileStore.profile(for: scope, modelContext: fresh))
            #expect(profile.profileOnboardingStep == expected[step])
            #expect(profile.profileOnboardingCompletedAt == nil)
            #expect(Self.gate(Self.authenticated(Self.accountA, provider: "apple"), .account(Self.accountA), fresh) == Self.accountA)
            let resumed = ProfileOnboardingDraft(
                profile: profile,
                latestWeightKg: LatestBodyWeightResolver.latestWeightKg(scope: scope, modelContext: fresh)
            )
            #expect(resumed.heightCm == 178)
            #expect(resumed.currentWeightKg == 72.5)
            #expect(resumed.activityFactor == .active)
        }
        let context = ModelContext(container)
        let profile = try #require(UserProfileStore.profile(for: scope, modelContext: context))
        let resumed = ProfileOnboardingDraft(profile: profile, latestWeightKg: nil)
        #expect(resumed.trainingGoal == .strength)
        #expect(resumed.weeklyChangeKg == 0.2)
        #expect(resumed.preferredSessionMinutes == 60)
        #expect(resumed.experienceLevel == .intermediate)
    }

    @Test("Progress is per account: A's resume point is not B's, and survives B signing in")
    func progressIsAccountScoped() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        #expect(Self.validDraft().save(.basics, to: .account(Self.accountA), modelContext: context) != nil)
        #expect(Self.validDraft().save(.basics, to: .account(Self.accountB), modelContext: context) != nil)
        #expect(Self.validDraft().save(.goal, to: .account(Self.accountB), modelContext: context) != nil)
        try context.save()

        let fresh = ModelContext(container)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: fresh)?.profileOnboardingStep == .goal)
        #expect(UserProfileStore.profile(for: .account(Self.accountB), modelContext: fresh)?.profileOnboardingStep == .habits)
        #expect(UserProfileStore.profile(for: .guest, modelContext: fresh) == nil)
    }

    @Test("Deleting the account deletes its half-finished progress")
    func accountDeletionForgetsProgress() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        #expect(Self.validDraft().save(.basics, to: .account(Self.accountA), modelContext: context) != nil)
        try context.save()
        let defaults = try #require(UserDefaults(suiteName: "profile-onboarding-\(UUID().uuidString)"))
        try AccountLocalDataCleanup(container: container, defaults: defaults).run(for: Self.accountA)

        let fresh = ModelContext(container)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: fresh) == nil)
        #expect(ProfileOnboardingDraft(profile: nil, latestWeightKg: nil).goalWeightKg == nil)
    }

    @Test("A profile from before V10 (no marker, no progress) starts at basics")
    func legacyProfileStartsAtBasics() {
        let profile = UserProfile(ownerAccountID: Self.accountA)
        #expect(profile.profileOnboardingStepRaw == nil)
        #expect(profile.profileOnboardingStep == .basics)
        profile.profileOnboardingStepRaw = "someFutureStep"
        #expect(profile.profileOnboardingStep == .basics)
    }

    @Test("Session minutes use Quick Plan's grid; weekly change starts from the goal")
    func sharedRangesAndGoalSuggestion() {
        #expect(ProfileFieldRanges.sessionMinutes == QuickPlanDuration.minMinutes...QuickPlanDuration.maxMinutes)
        #expect(ProfileFieldRanges.sessionMinutesStep == QuickPlanDuration.stepMinutes)
        let offered = Array(stride(
            from: ProfileFieldRanges.sessionMinutes.lowerBound,
            through: ProfileFieldRanges.sessionMinutes.upperBound,
            by: ProfileFieldRanges.sessionMinutesStep
        ))
        #expect(offered == QuickPlanDuration.allCases.map(\.minutes))
        #expect(offered.allSatisfy(ProfileFieldRanges.isValidSessionMinutes))
        #expect(ProfileFieldRanges.isValidSessionMinutes(ProfileFieldRanges.defaultSessionMinutes))

        // A new draft does not inherit the profile's weight-loss default.
        #expect(ProfileOnboardingDraft(profile: nil, latestWeightKg: nil).weeklyChangeKg == 0)
        #expect(ProfileTrainingGoal.fatLoss.suggestedWeeklyChangeKg < 0)
        for goal in [ProfileTrainingGoal.hypertrophy, .strength, .health, .consistency] {
            #expect(goal.suggestedWeeklyChangeKg >= 0)
            #expect(ProfileFieldRanges.weeklyChangeKg.contains(goal.suggestedWeeklyChangeKg))
        }
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
        #expect(account.profileOnboardingStep == .basics)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.heightCm == 180)

        // Migrated, never onboarded: the account is asked once.
        #expect(Self.gate(Self.authenticated(Self.accountA, provider: "apple"), .account(Self.accountA), context) == Self.accountA)
    }
}

// MARK: - First launch

extension ProfileOnboardingTests {

    private static func firstLaunch(
        _ state: ServerAccountState,
        _ scope: WorkoutDataScope,
        _ context: ModelContext
    ) -> FirstLaunchSignIn.Step {
        FirstLaunchSignIn.step(state: state, scope: scope, answers: noAnswers, in: context)
    }

    @Test("First launch stays on the choices until the server confirms an account")
    func firstLaunchWaitsForAConfirmedAccount() throws {
        let context = ModelContext(try Self.makeContainer())

        #expect(Self.firstLaunch(.guest, .guest, context) == .choose)
        #expect(Self.firstLaunch(.unreachable, .account(Self.accountA), context) == .choose)
        // Confirmed, but the app is not yet showing that account.
        #expect(Self.firstLaunch(Self.authenticated(Self.accountA, provider: "apple"), .undetermined, context) == .choose)
    }

    @Test("A new Apple or Google account goes to profile onboarding, then Home", arguments: ["apple", "google"])
    func firstLaunchOnboardsTheProfileBeforeHome(provider: String) throws {
        let context = ModelContext(try Self.makeContainer())
        let state = Self.authenticated(Self.accountA, provider: provider)

        #expect(Self.firstLaunch(state, .account(Self.accountA), context) == .profile(Self.accountA))

        // Stopping part-way keeps it on the profile, at the saved step.
        #expect(Self.validDraft().save(.basics, to: .account(Self.accountA), modelContext: context, now: Self.now) != nil)
        try context.save()
        #expect(Self.firstLaunch(state, .account(Self.accountA), context) == .profile(Self.accountA))

        try Self.finish(Self.accountA, context)
        #expect(Self.firstLaunch(state, .account(Self.accountA), context) == .finished)
    }

    /// Guest health data and a guest profile on the device, and account A
    /// confirmed by the server: the adoption question is open.
    private static func guestDataAndSignedIn(_ provider: String) throws -> (ModelContext, ServerAccountState, GuestAdoptionConsent.Question) {
        let context = ModelContext(try makeContainer())
        context.insert(UserProfile(heightCm: 158, ageYears: 25, goalWeightKg: 50))
        context.insert(DayLog(date: DateUtils.startOfDay(now), weightKg: 54))
        try context.save()
        let question = try #require(GuestAdoptionConsent.question(for: accountA, answers: noAnswers, in: context))
        return (context, authenticated(accountA, provider: provider), question)
    }

    @Test("An open adoption question never finishes first launch; accepting leads to the profile", arguments: ["apple", "google"])
    func firstLaunchWaitsForAdoptionThenAccept(provider: String) throws {
        let (context, state, question) = try Self.guestDataAndSignedIn(provider)

        #expect(FirstLaunchSignIn.step(state: state, scope: .account(Self.accountA), answers: Self.noAnswers, in: context)
            == .awaitingGuestAdoption(Self.accountA))

        var answers = Self.noAnswers
        try GuestAdoptionConsent.accept(question, answers: &answers, in: context)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context)?.heightCm == 158)
        #expect(FirstLaunchSignIn.step(state: state, scope: .account(Self.accountA), answers: answers, in: context)
            == .profile(Self.accountA))

        try Self.finish(Self.accountA, context)
        #expect(FirstLaunchSignIn.step(state: state, scope: .account(Self.accountA), answers: answers, in: context)
            == .finished)
    }

    @Test("Declining adoption keeps the guest data and still leads to the profile before Home")
    func firstLaunchWaitsForAdoptionThenDecline() throws {
        let (context, state, question) = try Self.guestDataAndSignedIn("apple")

        let answers = Self.noAnswers.marking(question)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context) == nil)
        #expect(try HealthDataAdoptionStore().hasGuestHealthData(in: context))
        #expect(FirstLaunchSignIn.step(state: state, scope: .account(Self.accountA), answers: answers, in: context)
            == .profile(Self.accountA))

        try Self.finish(Self.accountA, context)
        #expect(FirstLaunchSignIn.step(state: state, scope: .account(Self.accountA), answers: answers, in: context)
            == .finished)
    }

    // MARK: - Wheels

    @Test("A new draft's age starts at 20; an existing profile keeps its saved age")
    func ageDefaults() {
        #expect(ProfileOnboardingDraft(profile: nil, latestWeightKg: nil).ageYears == 20)
        let existing = UserProfile(ageYears: 41, ownerAccountID: Self.accountA)
        #expect(ProfileOnboardingDraft(profile: existing, latestWeightKg: nil).ageYears == 41)
        // UserProfile's own default is unchanged; only onboarding starts at 20.
        #expect(UserProfile().ageYears == 30)
    }

    @Test("Each wheel spans exactly its ProfileFieldRanges range in its step")
    func wheelBounds() {
        let cases: [(NumericWheelScale, Double, Double, Double, Int)] = [
            (.ageYears, 10, 100, 1, 91),
            (.heightCm, 120, 220, 1, 101),
            (.bodyWeightKg, 30, 250, 0.1, 2201),
            (.goalWeightKg, 30, 150, 0.5, 241),
            (.weeklyChangeKg, -1.5, 1.5, 0.1, 31),
            (.trainingDaysPerWeek, 1, 7, 1, 7),
            (.sessionMinutes, 30, 180, 15, 11),
        ]
        for (scale, min, max, step, count) in cases {
            #expect(scale.minValue == min)
            #expect(scale.maxValue == max)
            #expect(scale.step == step)
            #expect(scale.count == count)
        }
        #expect(NumericWheelScale.ageYears.minValue == Double(ProfileFieldRanges.ageYears.lowerBound))
        #expect(NumericWheelScale.sessionMinutes.maxValue == Double(QuickPlanDuration.maxMinutes))
        // Every session wheel row is a length Quick Plan can offer.
        for index in 0..<NumericWheelScale.sessionMinutes.count {
            #expect(ProfileFieldRanges.isValidSessionMinutes(Int(NumericWheelScale.sessionMinutes.value(at: index))))
        }
    }

    @Test("Wheel values are exact on their grid: 0.1 kg current, 0.5 kg goal, 0.1 kg weekly")
    func wheelResolution() {
        let current = NumericWheelScale.bodyWeightKg
        #expect(current.value(at: current.index(nearest: 72.5)) == 72.5)
        #expect(current.value(at: 3) == 30.3)
        #expect(current.snapped(72.46) == 72.5)
        #expect(current.snapped(400) == 250)
        #expect(current.text(72) == "72.0")

        let goal = NumericWheelScale.goalWeightKg
        #expect(goal.value(at: 1) == 30.5)
        #expect(goal.snapped(70.2) == 70)
        #expect(goal.snapped(70.3) == 70.5)

        let weekly = NumericWheelScale.weeklyChangeKg
        #expect(weekly.value(at: 0) == -1.5)
        #expect(weekly.value(at: 13) == -0.2)
        #expect(weekly.snapped(-0.5) == -0.5)
        #expect(weekly.text(0.2, signed: true) == "+0.2")

        let minutes = NumericWheelScale.sessionMinutes
        #expect(minutes.value(at: 1) == 45)
        #expect(minutes.snapped(50) == 45)
    }

    @Test("Weights are saved at the wheels' precision and resumed onto the wheel")
    func weightPrecisionRoundTrips() throws {
        let container = try Self.makeContainer()
        let scope = HealthDataScope.account(Self.accountA)
        var draft = Self.validDraft()
        draft.currentWeightKg = NumericWheelScale.bodyWeightKg.value(at: NumericWheelScale.bodyWeightKg.index(nearest: 68.3))
        draft.goalWeightKg = 64.5
        draft.weeklyChangeKg = NumericWheelScale.weeklyChangeKg.snapped(-0.3)
        let context = ModelContext(container)
        for step in [ProfileOnboardingStep.basics, .goal] {
            #expect(draft.save(step, to: scope, modelContext: context, now: Self.now) != nil)
        }
        try context.save()

        let fresh = ModelContext(container)
        #expect(DayLogStore.fetch(date: Self.now, scope: scope, modelContext: fresh)?.weightKg == 68.3)
        let profile = try #require(UserProfileStore.profile(for: scope, modelContext: fresh))
        #expect(profile.goalWeightKg == 64.5)
        #expect(profile.weeklyChangeKg == -0.3)
        let resumed = ProfileOnboardingDraft(
            profile: profile,
            latestWeightKg: LatestBodyWeightResolver.latestWeightKg(scope: scope, modelContext: fresh)
        )
        #expect(resumed.currentWeightKg == 68.3)
        #expect(resumed.goalWeightKg == 64.5)
        #expect(resumed.weeklyChangeKg == -0.3)
        #expect(resumed.ageYears == 34)
    }

    @Test("Off-grid stored weights open on the nearest wheel row; out-of-range ones stay unset")
    func offGridWeightsSnap() {
        let profile = UserProfile(goalWeightKg: 70.2, ownerAccountID: Self.accountA)
        let draft = ProfileOnboardingDraft(profile: profile, latestWeightKg: 72.46)
        #expect(draft.currentWeightKg == 72.5)
        #expect(draft.goalWeightKg == 70)

        let outOfRange = UserProfile(goalWeightKg: 200, ownerAccountID: Self.accountA)
        let unset = ProfileOnboardingDraft(profile: outOfRange, latestWeightKg: 300)
        #expect(unset.currentWeightKg == nil)
        #expect(unset.goalWeightKg == nil)
        #expect(!unset.isValid(.basics))
    }

    @Test("Current weight on two wheels: 30.0 to 250.0 in 0.1, never past 250.0")
    func currentWeightSplitWheel() {
        let scale = NumericWheelScale.bodyWeightKg
        #expect(scale.wholeNumbers == 30...250)
        #expect(scale.fractionCount == 10)
        #expect((0..<10).map(scale.fractionText) == [".0", ".1", ".2", ".3", ".4", ".5", ".6", ".7", ".8", ".9"])
        for (value, whole, fraction) in [(30.0, 30, 0), (82.5, 82, 5), (249.9, 249, 9), (250.0, 250, 0)] {
            #expect(scale.value(whole: whole, fraction: fraction) == value)
            #expect(scale.parts(of: value) == (whole, fraction))
        }
        // 249 offers every tenth; 250 offers .0 alone.
        #expect(scale.fractions(forWhole: 249) == 0..<10)
        #expect(scale.fractions(forWhole: 30) == 0..<10)
        #expect(scale.fractions(forWhole: 250) == 0..<1)
        // Turning the whole wheel from 249.9 to 250 lands on 250.0.
        let from = scale.parts(of: 249.9)
        let moved = scale.value(whole: 250, fraction: from.fraction)
        #expect(moved == 250.0)
        #expect(scale.parts(of: moved) == (250, 0))
        #expect(scale.parts(of: 250.9) == (250, 0))
    }

    @Test("Goal weight on two wheels: 30.0 to 150.0 in 0.5, never 150.5")
    func goalWeightSplitWheel() {
        let scale = NumericWheelScale.goalWeightKg
        #expect(scale.wholeNumbers == 30...150)
        #expect(scale.fractionCount == 2)
        #expect((0..<2).map(scale.fractionText) == [".0", ".5"])
        for (value, whole, fraction) in [(30.0, 30, 0), (70.5, 70, 1), (150.0, 150, 0)] {
            #expect(scale.value(whole: whole, fraction: fraction) == value)
            #expect(scale.parts(of: value) == (whole, fraction))
        }
        #expect(scale.value(whole: 149, fraction: 1) == 149.5)
        #expect(scale.fractions(forWhole: 149) == 0..<2)
        #expect(scale.fractions(forWhole: 150) == 0..<1)
        let moved = scale.value(whole: 150, fraction: scale.parts(of: 149.5).fraction)
        #expect(moved == 150.0)
        #expect(scale.parts(of: moved) == (150, 0))
        // Off-grid snaps to the nearest half kilo.
        #expect(scale.parts(of: 70.7) == (70, 1))
        #expect(scale.parts(of: 70.8) == (71, 0))
    }
}
