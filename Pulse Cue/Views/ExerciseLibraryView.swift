import SwiftUI

/// A lightweight read-only index for finding an authored Form Guide.
/// It uses bundled ExerciseLibrary/FormGuideLibrary data only.
struct ExerciseLibraryView: View {
    @State private var searchText = ""
    @State private var presentedExercise: ExerciseID?

    init() {}

#if DEBUG
    /// DEBUG-only: opens the library with a preset search query for
    /// deterministic inventory screenshots (search-results / no-results).
    /// Does not change normal production behavior — the field is still fully
    /// editable and defaults to empty on the production path.
    init(debugInitialSearch: String) {
        _searchText = State(initialValue: debugInitialSearch)
    }
#endif

    private var guidedExercises: [Exercise] {
        ExerciseLibrary.all.filter { FormGuideLibrary.hasGuide(for: $0.id) }
    }

    private var results: [Exercise] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return guidedExercises }
        return guidedExercises.filter { exercise in
            exercise.displayName.localizedCaseInsensitiveContains(query)
                || exercise.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || exercise.bodyParts.contains(where: {
                    $0.displayName.localizedCaseInsensitiveContains(query)
                })
        }
    }

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 24)

                    if results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, exercise in
                            Button {
                                presentedExercise = exercise.id
                            } label: {
                                exerciseRow(exercise)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("フォームガイドを表示")

                            if index < results.count - 1 {
                                Divider()
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("種目ライブラリ")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "種目名・部位で検索")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .sheet(item: $presentedExercise) { exerciseId in
            ExerciseGuideView(exerciseId: exerciseId)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("フォームを確認する")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("種目を選ぶと、3Dとテキストで動きを確認できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon(for: exercise.primaryBodyPart))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppTheme.accentSoft))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(exercise.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(exercise.bodyParts.map(\.displayName).joined(separator: "・"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 68)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "一致する種目がありません",
            systemImage: "magnifyingglass",
            description: Text("検索ワードを変えて試してください。")
        )
    }

    private func icon(for bodyPart: BodyPart) -> String {
        switch bodyPart {
        case .chest: return "figure.strengthtraining.traditional"
        case .back: return "figure.walk"
        case .legs: return "figure.run"
        case .shoulders: return "figure.archery"
        case .arms: return "dumbbell"
        case .core: return "figure.core.training"
        case .fullBody: return "figure.mixed.cardio"
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ExerciseLibraryView()
    }
}
#endif
