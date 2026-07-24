//
//  ExerciseGuide.swift
//  Pulse Cue
//
//  Static, text-only form-guide content, kept separate from `Exercise`
//  identity so the two evolve independently. This PR ships a genuinely
//  useful *text* guide; there is no 3D asset and no placeholder animation
//  reference (`animationAssetId` is intentionally `nil`). A later
//  iOS-17-compatible RealityKit PR will fill `animationAssetId` and use
//  `recommendedViews` to drive camera presets — without redesigning the
//  guide screen.
//
//  Content principles (see task §14): concise, honest, no medical or
//  injury-prevention certainty. A single shared disclaimer
//  (`FormGuideLibrary.sharedDisclaimer`) carries the "痛みがあれば中止"
//  message so each guide stays short.
//

import Foundation

/// A camera viewpoint a guide recommends. Drives future 3D presets; today
/// it is only metadata (optionally surfaced as a small hint).
enum RecommendedView: String, Hashable, CaseIterable, Sendable {
    case front
    case side
    case rear

    var displayName: String {
        switch self {
        case .front: return "正面"
        case .side: return "側面"
        case .rear: return "背面"
        }
    }
}

/// Text guide for one exercise. Bound to a stable `ExerciseID`; the
/// `animationAssetId` is reserved for the future 3D pack and is `nil` here.
struct ExerciseGuide: Identifiable, Hashable, Sendable {
    var id: ExerciseID { exerciseId }
    let exerciseId: ExerciseID
    /// 2–4 short movement steps.
    let instructions: [String]
    /// 2–4 high-signal mistakes to avoid.
    let commonMistakes: [String]
    /// 1–3 concise check points.
    let safetyNotes: [String]
    /// Preferred camera angles for the future 3D viewer.
    let recommendedViews: [RecommendedView]
    /// Reserved for the future 3D pack. `nil` in this PR — no placeholder.
    let animationAssetId: String?

    init(
        exerciseId: ExerciseID,
        instructions: [String],
        commonMistakes: [String],
        safetyNotes: [String],
        recommendedViews: [RecommendedView],
        animationAssetId: String? = nil
    ) {
        self.exerciseId = exerciseId
        self.instructions = instructions
        self.commonMistakes = commonMistakes
        self.safetyNotes = safetyNotes
        self.recommendedViews = recommendedViews
        self.animationAssetId = animationAssetId
    }
}

enum FormGuideLibrary {

    /// Compact shared disclaimer shown once per guide. Deliberately not
    /// repeated inside each section, and deliberately free of any
    /// "怪我を防げる / 正しさを保証" claim.
    static let sharedDisclaimer =
        "基本的な動作の参考です。使用するマシンの案内を優先し、痛みや違和感がある場合は中止してください。"

    /// The MVP guide pack: ~10 machine-focused movements. Keys are stable
    /// `ExerciseID`s that exist in `ExerciseLibrary`.
    static let all: [ExerciseGuide] = [
        ExerciseGuide(
            exerciseId: "machine_chest_press",
            instructions: [
                "シートを調整し、グリップが胸の高さにくる位置に座る",
                "肩甲骨を軽く寄せ、背中をパッドに預ける",
                "息を吐きながら前方へ押し、コントロールして戻す",
            ],
            commonMistakes: [
                "肘を伸ばし切ってロックしてしまう",
                "肩がすくんで首まわりに力が入る",
                "戻すときに一気に脱力する",
            ],
            safetyNotes: [
                "胸の張りを保ち、反動を使わない",
                "無理のない重さから始める",
            ],
            recommendedViews: [.side, .front]
        ),
        ExerciseGuide(
            exerciseId: "lat_pulldown",
            instructions: [
                "パッドで太ももを固定し、バーを肩幅より少し広く握る",
                "胸を軽く張り、肘を下へ引くイメージでバーを鎖骨付近へ",
                "背中の収縮を感じたら、コントロールして戻す",
            ],
            commonMistakes: [
                "腕の力だけで引いてしまう",
                "体を大きく後ろに倒して反動を使う",
                "バーを首の後ろへ下ろす",
            ],
            safetyNotes: [
                "肘で引く意識で広背筋を使う",
                "戻すときも力を抜きすぎない",
            ],
            recommendedViews: [.front, .side]
        ),
        ExerciseGuide(
            exerciseId: "machine_seated_row",
            instructions: [
                "胸をパッドにあて、ハンドルを握る",
                "胸を張って肩甲骨を寄せながら、みぞおちへ引く",
                "背中の収縮を感じたら、コントロールして戻す",
            ],
            commonMistakes: [
                "背中を丸めたまま引く",
                "反動で体を大きく揺らす",
                "肩がすくんでしまう",
            ],
            safetyNotes: [
                "肩甲骨を寄せる動きを意識する",
                "腰は反らしすぎない",
            ],
            recommendedViews: [.side, .rear]
        ),
        ExerciseGuide(
            exerciseId: "machine_shoulder_press",
            instructions: [
                "シートを調整し、グリップが肩の高さにくる位置に座る",
                "背中をパッドに預け、頭の上方向へ押し上げる",
                "コントロールして肩の高さまで戻す",
            ],
            commonMistakes: [
                "腰を大きく反らして押し上げる",
                "肘を完全にロックする",
                "肩がすくんで首に力が入る",
            ],
            safetyNotes: [
                "軌道は頭の真上を意識する",
                "無理のない可動域で行う",
            ],
            recommendedViews: [.front, .side]
        ),
        ExerciseGuide(
            exerciseId: "leg_press",
            instructions: [
                "足をプレートの中央に肩幅で置く",
                "膝がつま先と同じ向きになるようにゆっくり下ろす",
                "かかとで押し返し、膝はロックしない",
            ],
            commonMistakes: [
                "膝が内側に入る",
                "かかとが浮いてつま先重心になる",
                "下ろす範囲が浅すぎる／深すぎる",
            ],
            safetyNotes: [
                "膝とつま先の向きをそろえる",
                "腰がシートから浮かない範囲で下ろす",
            ],
            recommendedViews: [.side, .front]
        ),
        ExerciseGuide(
            exerciseId: "leg_extension",
            instructions: [
                "膝の回転軸がマシンの軸に合う位置に座る",
                "足首のパッドを脛の下側にあてる",
                "膝を伸ばして持ち上げ、上で軽く止めてから戻す",
            ],
            commonMistakes: [
                "反動で脚を振り上げる",
                "戻すときに一気に脱力する",
                "お尻がシートから浮く",
            ],
            safetyNotes: [
                "大腿四頭筋の収縮を意識する",
                "膝に痛みが出ない範囲で行う",
            ],
            recommendedViews: [.side]
        ),
        ExerciseGuide(
            exerciseId: "leg_curl",
            instructions: [
                "膝の回転軸をマシンの軸に合わせる",
                "パッドをアキレス腱の少し上にあてる",
                "かかとをお尻へ引きつけ、コントロールして戻す",
            ],
            commonMistakes: [
                "腰を反らせて反動を使う",
                "戻すときに力を抜きすぎる",
                "お尻や腰が浮いてしまう",
            ],
            safetyNotes: [
                "ハムストリングスの動きを意識する",
                "戻す動作もゆっくり行う",
            ],
            recommendedViews: [.side]
        ),
        ExerciseGuide(
            exerciseId: "machine_arm_curl",
            instructions: [
                "肘をパッドにのせ、脇を軽く締める",
                "肘を固定したまま、グリップを持ち上げる",
                "上腕二頭筋の収縮を感じたら、コントロールして戻す",
            ],
            commonMistakes: [
                "肘がパッドから浮いて反動を使う",
                "戻すときに一気に脱力する",
                "手首を丸め込みすぎる",
            ],
            safetyNotes: [
                "肘の位置を固定して二頭筋で挙げる",
                "無理のない重さで行う",
            ],
            recommendedViews: [.front, .side]
        ),
        ExerciseGuide(
            exerciseId: "cable_triceps_pushdown",
            instructions: [
                "ケーブルを高い位置にセットし、バーを肩幅で握る",
                "肘を体側に固定し、前腕だけを下へ押し下げる",
                "下で軽く止め、コントロールして戻す",
            ],
            commonMistakes: [
                "肘が前後に動いてしまう",
                "上体を大きく前に倒して体重で押す",
                "戻すときに肘が開く",
            ],
            safetyNotes: [
                "肘を体側に固定して伸ばし切る",
                "肩がすくまないようにする",
            ],
            recommendedViews: [.side, .front]
        ),
        ExerciseGuide(
            exerciseId: "machine_lateral_raise",
            instructions: [
                "シートに座り、パッドの下に上腕の外側をあてる",
                "肩の高さまで腕を横に持ち上げる",
                "コントロールしながらゆっくり戻す",
            ],
            commonMistakes: [
                "反動で一気に持ち上げる",
                "肩がすくんで首に力が入る",
                "肩より高く上げすぎる",
            ],
            safetyNotes: [
                "三角筋の中部で挙げる意識",
                "肩の高さ付近までにとどめる",
            ],
            recommendedViews: [.front]
        ),
    ]

    private static let byId: [ExerciseID: ExerciseGuide] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.exerciseId, $0) })
    }()

    /// Text guide for a stable id, or `nil` when none exists.
    static func guide(for id: ExerciseID) -> ExerciseGuide? { byId[id] }

    /// Convenience: guide for an optional id (custom / unresolved → nil).
    static func guide(for id: ExerciseID?) -> ExerciseGuide? {
        id.flatMap { byId[$0] }
    }

    /// Whether a supported guide exists for this id. Custom/unresolved
    /// exercises (`nil`) never have a guide.
    static func hasGuide(for id: ExerciseID?) -> Bool {
        guide(for: id) != nil
    }
}
