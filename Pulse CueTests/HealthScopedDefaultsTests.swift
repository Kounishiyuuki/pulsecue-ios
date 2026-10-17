//
//  HealthScopedDefaultsTests.swift
//  Pulse CueTests
//
//  Favorite meals and manual health targets, per Guest / A / B: each scope
//  sees and writes only its own, undetermined sees nothing and writes
//  nothing, the pre-account global value is guest's alone, and an A → B
//  switch on the same store instance never shows A's values under B.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct HealthScopedDefaultsTests {

    private static let a = HealthDataScope.account(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!)
    private static let b = HealthDataScope.account(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000B1")!)
    private static let favoritesKey = FavoriteMealTemplateStore.defaultStorageKey
    private static let targetsKey = "health.targetSettings.v1"
    private static let monday = DateUtils.startOfDay(Date(timeIntervalSinceReferenceDate: 800_000_000))

    private static func makeDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "HealthScopedDefaultsTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func template(_ name: String) -> FavoriteMealTemplate {
        FavoriteMealTemplate(name: name, kcal: 100, slot: .lunch)
    }

    // MARK: - Keys

    @Test
    func keysAreNamespacedByServerUUIDAndUndeterminedHasNone() {
        let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!
        #expect(HealthScopedDefaults.key("base", for: .guest) == "base.guest")
        #expect(HealthScopedDefaults.key("base", for: .account(id)) == "base.account.AAAAAAAA-0000-0000-0000-0000000000A1")
        #expect(HealthScopedDefaults.key("base", for: .undetermined) == nil)
    }

    // MARK: - Favorites

    private static func seededFavorites(_ defaults: UserDefaults) -> FavoriteMealTemplateStore {
        for (scope, name) in [(HealthDataScope.guest, "G"), (a, "A"), (b, "B")] {
            FavoriteMealTemplateStore(defaults: defaults, scope: scope).add(template(name), in: scope)
        }
        return FavoriteMealTemplateStore(defaults: defaults)
    }

    @Test
    func favoritesAreIsolatedPerScope() {
        let store = Self.seededFavorites(Self.makeDefaults())
        #expect(store.templates(in: .undetermined).isEmpty)
        for (scope, name) in [(HealthDataScope.guest, "G"), (Self.a, "A"), (Self.b, "B")] {
            store.use(scope)
            #expect(store.templates(in: scope).map(\.name) == [name])
        }
        store.use(.undetermined)
        #expect(store.templates(in: .undetermined).isEmpty)
        #expect(!store.add(Self.template("U"), in: .undetermined))
    }

    @Test
    func favoriteWritesInAStayInA() {
        let defaults = Self.makeDefaults()
        let store = Self.seededFavorites(defaults)
        store.use(Self.a)
        store.add(Self.template("A2"), in: Self.a)
        store.remove(store.templates(in: Self.a)[0], in: Self.a)
        #expect(store.templates(in: Self.a).map(\.name) == ["A2"])
        #expect(store.contains(name: "A2", kcal: 100, in: Self.a))
        #expect(!store.contains(name: "A2", kcal: 100, in: Self.b))

        let reader = FavoriteMealTemplateStore(defaults: defaults, scope: .guest)
        #expect(reader.templates(in: .guest).map(\.name) == ["G"])
        reader.use(Self.b)
        #expect(reader.templates(in: Self.b).map(\.name) == ["B"])
    }

    /// The same instance, A loaded, while the screen already asks for B:
    /// nothing of A's is readable or writable under B.
    @Test
    func favoritesNeverFlashAcrossASwitch() {
        let defaults = Self.makeDefaults()
        let store = Self.seededFavorites(defaults)
        store.use(Self.a)
        #expect(store.templates(in: Self.b).isEmpty)
        #expect(!store.contains(name: "A", kcal: 100, in: Self.b))
        #expect(!store.add(Self.template("stale"), in: Self.b))
        store.remove(store.templates(in: Self.a)[0], in: Self.b)

        store.use(Self.b)
        #expect(store.templates(in: Self.b).map(\.name) == ["B"])
        store.use(Self.a)
        #expect(store.templates(in: Self.a).map(\.name) == ["A"])
    }

    @Test
    func legacyFavoritesBelongToGuestOnly() throws {
        let defaults = Self.makeDefaults()
        defaults.set(try JSONEncoder().encode([Self.template("legacy")]), forKey: Self.favoritesKey)

        let store = FavoriteMealTemplateStore(defaults: defaults, scope: Self.a)
        #expect(store.templates(in: Self.a).isEmpty)
        store.use(Self.b)
        #expect(store.templates(in: Self.b).isEmpty)
        store.use(.guest)
        #expect(store.templates(in: .guest).map(\.name) == ["legacy"])

        // Copied once: a guest edit is not undone by the legacy key, which
        // itself is left for a downgrade.
        store.add(Self.template("G2"), in: .guest)
        let reopened = FavoriteMealTemplateStore(defaults: defaults, scope: .guest)
        #expect(reopened.templates(in: .guest).map(\.name) == ["legacy", "G2"])
        #expect(defaults.data(forKey: Self.favoritesKey) != nil)
    }

    // MARK: - Health targets

    private static func seededTargets(_ defaults: UserDefaults) -> HealthTargetStore {
        for (scope, kcal) in [(HealthDataScope.guest, 2000), (a, 2500), (b, 1800)] {
            let store = HealthTargetStore(defaults: defaults, scope: scope)
            store.updateDefaults(HealthTargets(intakeCalories: kcal), in: scope)
            store.updateWeekdayOverride(.monday, targets: HealthTargets(intakeCalories: kcal + 1), in: scope)
            store.updateDateOverride(monday, targets: HealthTargets(intakeCalories: kcal + 2), in: scope)
        }
        return HealthTargetStore(defaults: defaults)
    }

    @Test
    func targetsAreIsolatedPerScope() {
        let store = Self.seededTargets(Self.makeDefaults())
        #expect(store.settings(in: .undetermined) == .empty)
        for (scope, kcal) in [(HealthDataScope.guest, 2000), (Self.a, 2500), (Self.b, 1800)] {
            store.use(scope)
            let settings = store.settings(in: scope)
            #expect(settings.defaults.intakeCalories == kcal)
            #expect(settings.weekdayOverrides[.monday]?.intakeCalories == kcal + 1)
            #expect(settings.dateOverrides[Self.monday]?.intakeCalories == kcal + 2)
        }
        store.use(.undetermined)
        store.updateDefaults(HealthTargets(intakeCalories: 9999), in: .undetermined)
        #expect(store.settings(in: .undetermined) == .empty)
    }

    @Test
    func targetWritesInBDoNotTouchA() {
        let defaults = Self.makeDefaults()
        let store = Self.seededTargets(defaults)
        store.use(Self.b)
        store.updateDefaults(HealthTargets(intakeCalories: 1500), in: Self.b)
        store.clearWeekdayOverride(.monday, in: Self.b)
        store.clearDateOverride(Self.monday, in: Self.b)

        let a = HealthTargetStore(defaults: defaults, scope: Self.a).settings(in: Self.a)
        #expect(a.defaults.intakeCalories == 2500)
        #expect(a.weekdayOverrides[.monday]?.intakeCalories == 2501)
        #expect(a.dateOverrides[Self.monday]?.intakeCalories == 2502)
        let b = HealthTargetStore(defaults: defaults, scope: Self.b).settings(in: Self.b)
        #expect(b.defaults.intakeCalories == 1500)
        #expect(b.weekdayOverrides.isEmpty)
        #expect(b.dateOverrides.isEmpty)
    }

    @Test
    func targetsNeverFlashAcrossASwitch() {
        let defaults = Self.makeDefaults()
        let store = Self.seededTargets(defaults)
        store.use(Self.a)
        #expect(store.settings(in: Self.b) == .empty)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: Self.monday, settings: store.settings(in: Self.b)) == nil)
        store.updateDefaults(HealthTargets(intakeCalories: 1), in: Self.b)
        store.resetAll(in: Self.b)

        store.use(Self.b)
        #expect(store.settings(in: Self.b).defaults.intakeCalories == 1800)
        store.use(Self.a)
        #expect(store.settings(in: Self.a).defaults.intakeCalories == 2500)
    }

    @Test
    func legacyTargetsBelongToGuestOnly() {
        let defaults = Self.makeDefaults()
        let legacy = HealthTargetStore(defaults: defaults, storageKey: "scratch", scope: .guest)
        legacy.updateDefaults(HealthTargets(intakeCalories: 2100), in: .guest)
        // Put that blob where the pre-account build kept it.
        defaults.set(defaults.data(forKey: "scratch.guest"), forKey: Self.targetsKey)

        let store = HealthTargetStore(defaults: defaults, scope: Self.a)
        #expect(store.settings(in: Self.a) == .empty)
        store.use(Self.b)
        #expect(store.settings(in: Self.b) == .empty)
        store.use(.guest)
        #expect(store.settings(in: .guest).defaults.intakeCalories == 2100)
        #expect(defaults.data(forKey: Self.targetsKey) != nil)
    }
}
