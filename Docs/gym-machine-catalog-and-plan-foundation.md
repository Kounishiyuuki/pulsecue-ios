# ジムマシンカタログ と トレーニングプラン基盤の次世代設計

> **本ドキュメントの目的**: 既存の最小限なジムマシン関連実装を、より豊かなカタログモデルと
> 拡張されたプラン生成器に発展させるための設計を、コード変更の前に確定するための資料。
> **実装変更は含まない**（ドキュメントのみ）。外部 API・実 AI 連携・ネットワーキング・
> アカウント同期・SwiftData スキーマ変更は本 PR では一切行わない。
>
> 対象読者: 後続 PR で本基盤の拡張を担当する開発者。
> 作成日: 2026-05-25。

関連する既存仕様:
[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md)（AI 安全境界の鉄則）、
[`credential-strategy.md`](credential-strategy.md)（クライアントに長期キーを置かない方針）、
[`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md)（候補→レビュー→確定の
パターン例）。

---

## 1. 目的（Purpose）

PulseCue は v2 時点で「ジムからメニュー作成」フローを最小限の実装（後述）で持っているが、
次の段階に進むには:

- **より豊富なマシン情報**（カテゴリ・器具種別・主動筋 / 副動筋・難易度・初心者向け
  フラグ・セットアップ / 安全メモなど）が必要。
- **より柔軟なプラン生成**（部位単発でなく、目標 / 頻度 / セッション時間 / 分割パターン
  などを考慮した週間プラン）が必要。
- 将来は **AI チャットによるプラン相談**（候補→レビュー→確定の同じ境界を経由）を
  接続できる土台が必要。

これらは外部 API や AI を必要としない範囲で先に固められる。本ドキュメントは、まず
**ローカルファースト**でこの基盤を拡張するための設計を、コード変更の前に明文化する。

なぜ実 API / AI より先にこれを固めるか:

- ジムマシン情報は機微ではなく、ローカルに持っても合理性がある（写真や食事カロリーと
  違い、プロバイダ秘密や個人特定情報を扱わない）。
- 既存実装が小さく、互換性を保ったまま拡張する道筋を先に決められる。
- AI チャットを後付けする際も、AI は同じ候補型を生成するだけにすればよく、保存経路や
  レビュー画面を変えずに済む。

---

## 2. 現状（Current State — main 時点）

ジムマシンとプラン生成の最小限の実装は **既に存在する** ので、本 PR の設計はそこからの
拡張として記述する。重要な既存要素:

| 要素 | 場所 | 役割 |
|---|---|---|
| `BodyPart` 列挙 | `Pulse Cue/Models/BodyPart.swift` | 7 部位（chest / back / legs / shoulders / arms / core / fullBody）+ 日本語ラベル |
| `MachineCatalogEntry` / `MachineCatalog` | `Pulse Cue/Models/MachineCatalog.swift` | ローカル静的カタログ。16 マシン。フィールド: `id` / `displayName` / `bodyParts: Set<BodyPart>` |
| `Gym` / `GymMachine`（`@Model`） | `Pulse Cue/Models/Gym.swift` / `GymMachine.swift` | ユーザーが特定ジムで利用可能と確認したマシン行（`gymId` + `machineId` で結合、表示名はスナップショット） |
| `WorkoutPlanGenerator` | `Pulse Cue/Services/WorkoutPlanGenerator.swift`（165 行） | 純粋・決定論的 v0 ジェネレータ。`BodyPart` + `Gym` + `[GymMachine]` → `GeneratedPlan`。内部に `(BodyPart, machineId)` 別テンプレート表（exerciseName / sets / reps / restSeconds / cue） |
| `GeneratedPlan` / `GeneratedExercise` | 同上（value type） | 候補（candidate）値型。`bodyPart` / `gymId` / `gymName` / `exercises` / `warnings` / `defaultTitle` |
| `RoutineFactory` | `Pulse Cue/Services/RoutineFactory.swift` | 純粋アダプタ。`GeneratedPlan` → `Routine` + `[Step]`。**ModelContext には触らない**（呼び出し側が `insert` する） |
| `GeneratedPlanPreviewView` | `Pulse Cue/Views/GeneratedPlanPreviewView.swift` | **レビュー / 確定画面（既に存在）** |
| `MyGymHomeView` / `ManualMachineSelectionView` / `TargetBodyPartSelectionView` | `Pulse Cue/Views/...` | ジム / マシン選択・部位選択 UI |
| `TodayGymPlanCard` | 同上 | Today タブからの導線 |
| 既存テスト | `MachineCatalogTests` / `WorkoutPlanGeneratorTests` / `RoutineFactoryTests` / `GymRepositoryTests` | 重複 ID 検出、決定論、マッピング、永続化境界 |

**重要な観察**:

- **「候補 → レビュー → 確定 → 保存」の境界はすでに正しく実装されている**:
  `WorkoutPlanGenerator.generate(...)` が `GeneratedPlan` を返し、`GeneratedPlanPreviewView`
  が編集 / 確認 UI を提供し、確定時に `RoutineFactory.makeRoutine(from:)` が
  `Routine` + `Step` 値を作り、呼び出し側 ViewModel だけが `modelContext.insert(...)`
  する。本ドキュメントの提案はこの境界をそのまま継承する。
- **AI チャットプラン作成は未実装**。
- **外部 API（ジム機器データ取得）は未実装** で、当面追加しない。
- 既存カタログのフィールドは `(id, displayName, bodyParts)` の 3 つだけで、本 PR で
  提案する次世代モデル（§4）はその拡張になる。

---

## 3. 中核原則（Core Principles）

[`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md) や
[`photo-food-estimation-flow.md`](photo-food-estimation-flow.md) で確立してきた境界を
プラン生成にも適用する:

1. **ローカルファースト** — カタログはアプリ内に同梱。外部 API は当面導入しない。
2. **API は後回し** — 将来追加する場合も、AI / バックエンドに依存しないローカル経路は
   常に動き続けること。
3. **AI / 自動生成の出力は「候補」にすぎない** — `GeneratedPlan` は値型であり、ユーザー
   レビューを経るまで永続化されない。
4. **レビュー / 編集 / 確定の前に保存しない** — `Routine` / `Step` の `insert(...)` は
   ユーザーが確定ボタンを押した直後にのみ実行される（既存パターンを維持）。
5. **生成されたプランは確定後、通常の `Routine` / `Step` データとして扱われる** — その後
   の編集・複製・ピン留め・実行はすべて既存のワークアウト経路と同じ。
6. **手動ルーティン作成は引き続き利用可能** — `RoutineEditorView` から従来どおり作れる。
   プラン生成はそれを置き換えるものではなく、補助導線である。

---

## 4. マシンカタログモデルの次世代設計（拡張案）

現行 `MachineCatalogEntry` は `(id, displayName, bodyParts)` の最小モデル。これを以下の
**拡張モデル**へ段階的に発展させる。既存フィールドは保持し、新規フィールドはすべて
任意（optional）として追加する。

```swift
struct MachineCatalogEntry {
    // 既存（保持）
    let id: String                       // 例: "lat_pulldown"
    let displayName: String              // 例: "ラットプルダウン"
    let bodyParts: Set<BodyPart>         // 主に鍛える部位

    // 拡張（任意・段階導入）
    let category: BodyPart?              // 主カテゴリ（bodyParts の代表値）
    let equipmentType: EquipmentType?    // machine / cable / freeWeight / bodyweight / cardioMachine
    let targetMuscles: [Muscle]?         // 主動筋（例: latissimus_dorsi）
    let secondaryMuscles: [Muscle]?      // 副動筋
    let movementPattern: MovementPattern? // push / pull / squat / hinge / lunge / carry / core / cardio
    let difficulty: Difficulty?          // beginner / intermediate / advanced
    let beginnerFriendly: Bool?
    let setupNotes: String?              // 例: 「シートを胸の高さに調整」
    let safetyNotes: String?             // 例: 「腰を反らしすぎない」
    let defaultSets: Int?                // テンプレートのデフォルト（生成時のフォールバック）
    let defaultReps: Int?
    let defaultRestSeconds: Int?
    let tags: [String]?                  // 自由タグ（例: "barbell", "compound"）
}
```

附属の列挙（draft）:

- `EquipmentType`: `machine` / `cable` / `freeWeight` / `bodyweight` / `cardioMachine`
- `MovementPattern`: `push` / `pull` / `squat` / `hinge` / `lunge` / `carry` / `core` / `cardio`
- `Difficulty`: `beginner` / `intermediate` / `advanced`
- `Muscle`: 筋肉名の細かい列挙（最低限の運動学カバレッジでよい。`chest_clavicular`, `triceps`, `glutes` など）

`bodyParts` と `category` の関係: `category` は `bodyParts` の代表（プライマリ）で、
UI のフィルタ・グルーピングに使う。両方を保持しておくと、複合種目（例: ベンチプレスは
`bodyParts = {chest, arms}`、`category = .chest`）も自然に扱える。

### 既存実装との互換

- 現行 16 マシンはすべて新モデルに移行可能（新規フィールドはすべて任意なので、当面 nil
  のまま運用しても OK）。
- 段階導入: 「まず `equipmentType` と `category` を埋める」「次に `defaultSets/Reps`
  をテンプレートから移す」のように小さく刻む。
- 既存の `MachineCatalog.entries(for: BodyPart)` 等の API は維持。

---

## 5. ローカルデータソース戦略

- **第一段階: 同梱の静的カタログ** — 現行どおり Swift コードのリテラル（`MachineCatalog.all`
  の配列）。バンドル内に閉じ、ネットワークアクセスなし。
- **第二段階: 同梱 JSON / アセット** — エントリ数が増えてきたら JSON ファイル（Bundle
  リソース）に切り出し、`MachineCatalogLoader` 等のローダで読み込む形に移行可能。互換性
  を壊さないなら任意で進める。
- **第三段階以降: 外部データ取り込み** — 将来必要になった場合のみ検討。導入する場合も
  バンドルカタログを必ず残し、外部不通でも利用可能にする。
- **バージョン管理 / テスト**: 既存の `MachineCatalogTests`（ID 重複なし / ソート順
  維持）を流用し、新規フィールドも検証する（例: `category ?? bodyParts.first` の整合性）。

サーバー側カタログ（`server/src/parser/machines.ts`）との同期方針は現行と同じ（ドリフトを
PR diff で検知）。本 PR では server を一切変更しない。

---

## 6. マシン → ルーティンステップ マッピング

現行の流れは以下のとおりで、本基盤でも同じ:

```
MachineCatalogEntry（共通テンプレート）
  → WorkoutPlanGenerator の (BodyPart, machineId) テンプレート表
    → GeneratedExercise（候補：machineId / exerciseName / sets / reps / restSeconds / cue）
      → RoutineFactory.makeRoutine(from:) 経由で:
        → Routine + 順序付き [Step]
          → Runner で実行
```

### 次世代での変更点

- テンプレートの **データ源**: 現在は `WorkoutPlanGenerator` 内のハードコード表だが、
  リッチカタログ完成後は `MachineCatalogEntry.defaultSets/Reps/Rest` + 部位ごとの推奨
  種目名を組み合わせて派生させる（テンプレ表は当面残しつつ、徐々にカタログから自動生成
  へ移行）。
- ユーザーがレビュー画面で手動編集した値（sets / reps / restSeconds / 種目名）は引き続き
  尊重される。

---

## 7. ユーザー目標入力（拡張案）

現行 `WorkoutPlanGenerator.generate(...)` の入力は `BodyPart` + `Gym` + `[GymMachine]` の
1 セッション分のみ。次世代では以下を任意で受けられるようにする:

| 入力 | 値の例 |
|---|---|
| トレーニング目標 | `fatLoss` / `hypertrophy` / `strength` / `beginnerConsistency` |
| 週あたり頻度 | 1–6 回 / 週 |
| セッション時間目安 | 30 / 45 / 60 / 90 分 |
| 対象部位 | `[BodyPart]`（複数選択可） |
| 避ける部位 / 制限部位 | `[BodyPart]`（怪我等） |
| 利用可能な器具 | `availableMachines: [GymMachine]`（既存） |
| 経験レベル | `beginner` / `intermediate` / `advanced` |
| 分割パターン | `fullBody` / `upperLower` / `pushPullLegs` / `bodyPartSplit` |

すべて任意。指定がない場合は安全なデフォルト（例: `beginnerConsistency` / 3 回 / 45 分 /
fullBody）で生成する。

---

## 8. ルールベース ジェネレータ優先（AI より先）

実 AI を入れる前に、純粋関数のルールベースで以下まで実現する:

- 入力（§7）→ 週次プラン候補（複数セッション）への変換。
- マシンが少ない / 部位が足りないケースのフォールバック（既存 `WorkoutPlanGenerator` の
  `warnings` 機構を流用）。
- **決定論的・テスト可能**（同入力 → 同候補）。
- **ネットワーク・AI なし** — `Pulse Cue/Services/` の純粋ロジックとして実装。
- **自動保存しない** — `WorkoutPlanGenerator` と `RoutineFactory` の分離（前者は値を
  返すだけ）を維持する。

既存の `WorkoutPlanGeneratorTests` をベースに、週次プラン用テスト群を追加する。

---

## 9. プラン候補モデルの次世代設計

現行 `GeneratedPlan` は単一セッション。次世代では「週次プラン」を表す候補型を追加する
（既存の単一セッションプラン型と共存可）:

```swift
struct GeneratedWeeklyPlan {
    let title: String                 // 表示用タイトル
    let goal: TrainingGoal?
    let daysPerWeek: Int
    let sessions: [GeneratedSession]
    let rationale: String?            // 「なぜこの構成か」の短い説明
    let warnings: [String]            // 既存 GeneratedPlan と同じ運用
}

struct GeneratedSession {
    let title: String                 // 例: "上半身プッシュ"
    let bodyParts: [BodyPart]
    let exercises: [GeneratedExercise] // 既存型を流用
}
```

- 単一セッション生成は引き続き `GeneratedPlan` を返す（既存パスを壊さない）。
- 週次生成は `GeneratedWeeklyPlan` を返す（新パス）。
- 既存の `RoutineFactory.makeRoutine(from: GeneratedPlan)` はそのまま、新規に
  `RoutineFactory.makeRoutines(from: GeneratedWeeklyPlan) -> [Output]` を追加。各セッション
  を 1 つの `Routine` に変換する。

---

## 10. 候補 → レビュー → 確定 → 保存 のフロー

**既存パターンをそのまま継承する** — このフローはすでに正しく実装されている。

```
ユーザー目標入力（§7）
  → WorkoutPlanGenerator.generate(...)  ← 純粋関数。値型を返すだけ
    → GeneratedPlan / GeneratedWeeklyPlan（候補）
      → GeneratedPlanPreviewView（既存のレビュー画面、必要なら週次対応に拡張）
        → ユーザー編集（セッション / 種目 / セット / レップ / 休憩）
          → 「ルーティンとして保存」明示確定
            → RoutineFactory で Routine + [Step] を作成
              → 呼び出し側 ViewModel が modelContext.insert(...)
              → 必要に応じ複数 Routine（週次の場合）を順に登録
```

**絶対に守るルール**:

- 候補を保持しているだけでは `Routine` / `Step` は作られない。
- レビュー画面でキャンセル / 戻ると何も作られない（既存挙動を維持）。
- 保存はユーザーの明示確定操作の **後にのみ** 行う。
- `WorkoutPlanGenerator` と `RoutineFactory` は引き続き ModelContext に触らない。

---

## 11. AI チャット によるプラン相談（将来の概念のみ）

実装は **後続 PR**（後述）。AI 統合時も、同じ候補→レビュー→確定の境界を厳守する:

```
AI チャット（ユーザーが目標 / 制約を会話で伝える）
  → AI 応答（プラン草案 = 候補）
    → 候補値を GeneratedWeeklyPlan / GeneratedPlan に正規化
      → 既存のレビュー画面（編集可）
        → ユーザー明示確定
          → 既存の RoutineFactory 経由で Routine 保存
```

ルール:

- **AI が直接保存することは禁止**。出力は値型の候補で、必ず人間が確認する。
- AI は **ローカルカタログを参照する**（マシン id / 部位）。AI が自由文字列で種目名を
  発明しても、レビュー画面でユーザーが補正可能。
- 実 AI 統合は `Docs/photo-ai-provider-strategy.md` / `Docs/photo-ai-backend-token-spec.md`
  の方針（クライアントに長期キーを持たない / バックエンド経由）を踏襲する。
- AI チャット UI、プロバイダ抽象化、モッククライアントは別 PR で段階的に追加する。

---

## 12. テスト戦略

既存テストを活かしつつ、拡張時に追加すべき項目:

- **ローカルカタログの整合性** — `MachineCatalogTests` の拡張（重複 ID なし / 拡張フィールド
  の最小整合性 / カテゴリと部位の対応）。
- **マシンフィルタ** — `entries(for: BodyPart)` / `entries(for: MovementPattern)` /
  `entries(for: EquipmentType)` の単体テスト。
- **プラン生成の決定論** — `WorkoutPlanGenerator` の単一 / 週次両方で、同入力 →
  同出力を確認。新フィールド（目標 / 頻度 / 分割）ごとの分岐テスト。
- **`RoutineFactory` の純粋性** — ModelContext に触らないこと（既存テストを維持・拡張）。
- **レビュー / 保存境界** — 候補だけでは `Routine` が作られないこと、確定後にのみ作られる
  ことのテスト（既存パターンを踏襲）。
- **API / AI を使うテストは既定で書かない**。将来 AI 統合時はモック / フィクスチャを使う
  方針（写真 AI と同型）。

---

## 13. 将来 PR の分割案（既存実装との並存を前提）

既存実装は **そのまま動作させ続けながら**、段階的に拡張する。各 PR は前段の境界を
壊さないこと。

| PR | 内容 | 影響範囲 |
|---|---|---|
| **本 PR**（docs） | 本ドキュメント（次世代設計の確定） | docs のみ |
| **次（catalog 拡張）** | `MachineCatalogEntry` に任意フィールド追加（カテゴリ / equipmentType / movementPattern など）。既存 16 マシンを順次埋める。既存テストは通る | `MachineCatalog.swift` + tests |
| **マシン UI 拡張** | カテゴリ / 難易度フィルタを既存 `ManualMachineSelectionView` に追加 | views + view models |
| **テンプレ → カタログ駆動** | `WorkoutPlanGenerator` 内のテンプレート表を `MachineCatalogEntry.defaultSets/Reps/Rest` 等から派生に置き換え。後方互換 | generator + tests |
| **週次プラン生成 — 純粋ヘルパー** | `GeneratedWeeklyPlan` 値型 + ルールベース週次生成関数。既存単一セッション生成は不変 | generator + tests（新規） |
| **週次プランレビュー画面 / 保存フロー** | 既存 `GeneratedPlanPreviewView` を拡張して週次に対応、または並列に新規ビューを追加。`RoutineFactory.makeRoutines(from:)` 追加 | views + factory + tests |
| **AI チャットプラン草案 — ドキュメント** | チャット境界 / プロンプト方針 / 候補正規化ルールの仕様 | docs |
| **AI チャットプラン草案 — モック実装** | チャットプロトコル + モック実装 + 候補→既存レビュー画面接続。実 AI なし | services + tests |
| **AI / バックエンド統合（後日）** | `photo-ai-provider-strategy.md` 方針に従う | 後段 |

---

## 14. 明示的な非ゴール（Non-Goals）

本 PR および本基盤拡張の初期段階で **やらない / 認めない**:

- 外部ジム / マシン API の呼び出し。
- 実 AI プロバイダ統合、AI チャットの実装。
- クライアントへのプロバイダ API キー埋め込み。
- 候補のままでの `Routine` 自動保存。
- HealthKit 連携、アカウント / 同期。
- `server/` の変更。
- 本 docs PR での SwiftData スキーマ変更（既存の `Gym` / `GymMachine` / `Routine` /
  `Step` をそのまま使う）。
- 既存の手動ルーティン作成フローの削除や置換。

---

## 15. 実装着手前の受け入れ基準

後続 PR に進んでよいのは、次がすべて満たされたとき:

- [ ] §4 のカタログ拡張フィールド（特に `equipmentType` / `category` / `movementPattern` /
      `difficulty`）に合意がある。
- [ ] §6 のマシン → `Step` マッピング（テンプレ → カタログ駆動への移行手順）に合意がある。
- [ ] §10 の候補 → レビュー → 確定 → 保存の境界が現行と同じ形で維持されている。
- [ ] §13 の段階的並存戦略が承認されている（既存実装を壊さないこと）。
- [ ] 「API / AI を入れる前にローカルで完結する」方針が合意されている。
- [ ] 生成されたプランは確定後、通常の `Routine` / `Step` データとして読み書き編集できる
      ことが設計上明示されている。
- [ ] 手動ルーティン作成（`RoutineEditorView`）は引き続き利用可能であることが保証されている。

1 つでも未達なら、後続の実装 PR は着手しない。

---

## 関連ドキュメント

- [`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md) — AI / バックエンド
  統合の方針。AI チャットプラン作成（§11）はこの方針を踏襲する。
- [`photo-ai-backend-token-spec.md`](photo-ai-backend-token-spec.md) — クライアントに
  プロバイダ秘密を持たない構造の具体例。
- [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) — AI 安全境界の鉄則。
- [`manual-qa-checklist.md`](manual-qa-checklist.md) — 既存の「マイジム」「Today: ジムから
  メニュー作成カード」セクションが、現行プラン生成フローの動作確認手順を保持している。
