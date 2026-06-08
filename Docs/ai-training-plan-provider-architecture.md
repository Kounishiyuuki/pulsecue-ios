# AI トレーニングプラン プロバイダ アーキテクチャ決定（AI Training Plan Provider Architecture）

> **本ドキュメントの目的**: トレーニングプランの**実 AI 生成**を実装する **前に**、
> 推論の実行場所・クレデンシャルの扱い・プライバシー規則・リクエスト/レスポンス契約・
> エラー/レート制限・実装順序を確定するための設計資料。
> **実装変更は含まない**（ドキュメントのみ）。実 AI 連携・ネットワーク通信・API キー
> 処理・バックエンド変更・UI 実装は本 PR では一切行わない。
>
> 対象読者: 実 AI トレーニングプラン生成を担当する後続 PR の開発者。
> 作成日: 2026-06-01。

関連する既存仕様:
[`gym-machine-catalog-and-plan-foundation.md`](gym-machine-catalog-and-plan-foundation.md)（マシンカタログ / 週次プラン候補フロー全体の設計）、
[`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md)（写真 AI の同型の意思決定。本ドキュメントはその姉妹版）、
[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md)（AI 安全境界の鉄則）、
[`credential-strategy.md`](credential-strategy.md)（クライアントに長期キーを置かない方針）、
[`import-token-endpoint-spec.md`](import-token-endpoint-spec.md)（短期トークン方式のエンドポイント仕様）。

---

## 1. 目的（Purpose）

[`gym-machine-catalog-and-plan-foundation.md`](gym-machine-catalog-and-plan-foundation.md)
は週次プランの**アプリ内フロー**（候補 → レビュー → 確定 → 保存）と安全境界を定義した。
PR #74–#76 でその AI 版フローは**モックのみ**で実装済み（AI 計画境界、モック chat UI、
モック候補からの保存ハンドオフ）。

しかし**実 AI** を足すには、フロー設計とは別に次を決めなければならない:

- 推論をどこで行うか（端末内 / 自社バックエンド経由 / プロバイダ直叩き）。
- プロバイダの認証情報（API キー等）をどう扱うか。
- ユーザーの相談文（`userMessage`）という機微データをどこへ、いつ送るか。
- 課金・レート制限・障害時の挙動。
- プロバイダの未検証出力をどう検証・制限するか。

これらは**クレデンシャルとプライバシーの問題**であり、コードを書く前に確定すべき
意思決定である。本ドキュメントはその意思決定資料。実 AI は、本戦略が承認されるまで
実装しない。写真 AI の同型判断（[`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md)）と
結論を揃える。

---

## 2. 現状（Current State）

| 項目 | 状態 | PR |
|---|---|---|
| AI 計画境界（リクエスト/レスポンス値型・プロバイダ抽象・正規化） | 実装済み（`AITrainingPlanProvider.swift`） | #74 |
| モック chat UI（`AIプラン相談`） | 実装済み（`MockAITrainingPlanChatView`） | #75 |
| モック候補 → 明示保存ハンドオフ | 実装済み（`RoutineFactory.makeRoutines(from:)` + 明示 `modelContext.insert`） | #76 |
| iOS エンドポイントクライアント（`AITrainingPlanProviding` 実装） | 実装済み（`AITrainingPlanEndpointClient`。既定 UI に未配線） | #80 |
| プロバイダ選択境界（mock / endpoint の明示切替） | 実装済み（`AITrainingPlanProviderFactory`。既定は mock） | #81 |
| dev 専用 endpoint 配線（明示注入の seam） | 実装済み（`makeEndpointProvider(config:)` + `#if DEBUG` の `MockAITrainingPlanChatView(endpointConfiguration:)`。既定 UI は mock のまま） | #82 |
| 生成 UX のハードニング（loading / error / retry / cancel） | 実装済み（`AIPlanGenerationPhase` / `AIPlanGenerationError`。安全な日本語コピー・明示リトライ・キャンセル安全。実 endpoint は依然 既定ではない） | #83 |
| 実 AI プロバイダ | **未実装** | — |
| ネットワーク通信 / `userMessage` 送信 | **無し**（既定経路。endpoint は明示注入時のみ） | — |
| プロバイダ API キー / Worker URL | **アプリにもリポジトリにも存在しない** | — |

`AITrainingPlanProviding` には 2 つの実装がある: `MockAITrainingPlanProvider`（決定論的・
オフライン・RNG / clock / I/O なし）と `AITrainingPlanEndpointClient`（PR #80。バックエンド
プロキシを叩くネットワーク実装）。どちらを構築するかは `AITrainingPlanProviderFactory`
（PR #81）が決める。**既定は mock** で、`makeProvider()` を引数なしで呼ぶと
`MockAITrainingPlanProvider` が返る。endpoint 実装は、呼び出し側が
`AITrainingPlanEndpointConfiguration`（`baseURL` は必須・任意の `tokenProvider`）を
**明示的に注入したときだけ**構築される。本番 URL・トークン・シークレットはこの境界に
一切埋め込まれておらず、Info.plist / xcconfig / `UserDefaults` / Keychain / 環境変数からも
読まない。`MockAITrainingPlanChatView` は既定でこの factory 経由の mock を使い続ける。
endpoint 実装を画面に配線する経路は **dev 専用**（PR #82）: factory の
`makeEndpointProvider(config:)` と、`#if DEBUG` でのみコンパイルされる
`MockAITrainingPlanChatView(endpointConfiguration:)` 初期化子だけが endpoint プロバイダを
構築する。release ビルドにはこの seam が含まれず、`SettingsView` は常に引数なしで mock を
開く。本番でのプロバイダ有効化（ユーザー向けトグル等）は引き続き将来 PR の課題。
`AITrainingPlanNormalizer.normalize(response:request:catalog:)`
が生（未検証）の `AITrainingPlanResponse` を既存の `WeeklyTrainingPlanCandidate` に
正規化する（純粋・total・例外なし）。レビュー / 保存は実 AI とは独立しており、
`Routine` / `Step` はユーザーが「この候補を保存」を押したときにのみ作られる。

---

## 3. 中核ルール（Core Rules）

[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) の鉄則をトレーニングプラン AI に
適用したもの。**後続のすべての実装 PR はこれを守らなければならない。**

1. **iOS アプリに AI プロバイダの API キーを同梱しない。** 公開バイナリは展開・逆
   アセンブル可能であり、埋め込んだキーは抽出される（[`credential-strategy.md`](credential-strategy.md) の脅威モデル）。
   `Info.plist` / `xcconfig` / `UserDefaults` / ソースのいずれにも置かない。
2. **相談文の隠れた送信をしない。** `userMessage` が外部へ送られるのは、ユーザーが
   その画面でその操作（「プラン候補を作成」等）を明示的に行ったときだけ。
3. **ルーティンを自動作成しない。** AI 出力が確認前に `Routine` / `Step` になることは
   一切許されない。
4. **生成結果は「候補」にとどまる。** 実 AI の結果も `WeeklyTrainingPlanCandidate`
   候補にすぎず、確定済みデータではない。
5. **保存の前に必ずユーザーレビューを挟む。** `MockAITrainingPlanChatView` /
   `WeeklyTrainingPlanCandidateReviewView` での明示確定（「この候補を保存」/
   「週次プランを保存」）のみが保存経路。
6. **キャンセル / 離脱は何も作らない。** 画面を離脱したら候補は破棄、副作用ゼロ。
7. **正規化が最後の門番。** プロバイダ出力は必ず `AITrainingPlanNormalizer` を通す。

---

## 4. プロバイダ方式の候補（Candidate Provider Approaches）

実 AI 推論を「どこで・どう」行うかの 4 案を比較する。写真 AI の §4 と同じ枠組み。

| | **A. iOS → プロバイダ直叩き** | **B. iOS → PulseCue バックエンド → プロバイダ** | **C. 端末内モデル** | **D. ルールベースのみ（実 AI を入れない）** |
|---|---|---|---|---|
| **概要** | アプリが AI プロバイダ API を直接呼ぶ。キーはアプリ内 | アプリは自社バックエンド/Worker を呼び、そこがプロバイダを呼ぶ。プロバイダキーはサーバ側のみ | Core ML 等で端末内推論。外部通信なし | 実 AI を入れず、`RuleBasedWeeklyPlanGenerator` のみ |
| **セキュリティ** | 不可。長期キーがバイナリから抽出される | 良。プロバイダキーは iOS に降りてこない。iOS は短期トークンのみ保持 | 最良。秘密情報も送信も無い | 最良（外部依存なし） |
| **コスト** | プロバイダ課金が直接発生。乱用を止められない | プロバイダ課金 + バックエンド運用。サーバ側でレート制限・クォータ管理が可能 | 推論コストはゼロ。モデル同梱でアプリ容量増 | ゼロ |
| **プライバシー** | 相談文がプロバイダへ直行。経路の制御が弱い | 送信先・保持を自社境界で制御できる。ログ最小化を強制しやすい | 相談文が端末外に出ない。最良 | 送信なし |
| **実装労力** | 小（ただし不可なので採らない） | 中〜大（iOS の `TokenProvider` + バックエンド proxy） | 大（モデル選定・精度検証・容量最適化） | 0（実装済み） |
| **App Store 適合性** | キー埋め込みは規約・セキュリティ上不適 | 適 | 適 | 適 |
| **本番採用可否** | **不可** | **可（実クラウド AI を入れる場合の本命）** | 可（端末内で十分な品質が出るなら理想） | 可（実 AI を見送る場合の土台） |

補足:

- **A** は検討対象から外す。`#if DEBUG` ガードを付けても、AI プラン相談は公開機能であり
  デバッグ専用では意味がない。写真 AI とジム取り込みが出した結論と同じ。
- **B** は [`credential-strategy.md`](credential-strategy.md) の案 B（短期デバイス
  スコープトークン + App Attest）と同型。プロバイダキーは Worker secret として
  サーバ側にのみ存在し、iOS には短期トークンだけが降りる。
- **C** はトレーニングプランでは写真より現実味がある（テキスト入出力で画像処理が不要）。
  ただしモデル容量・品質は要検証。プライバシーが最良なので後続 PR で評価する価値はある。
- **D** は常に有効な土台。実 AI が無くても `RuleBasedWeeklyPlanGenerator` で週次プランは
  作れる。AI はあくまでオプション。

---

## 5. 推奨アプローチ（Recommended Approach）

- **iOS にプロバイダ API キーを直接置かない（案 A を不採用）。** 例外なし。
- **実クラウド AI を入れるなら案 B（バックエンド / トークン仲介）。** プロバイダ
  キーは自社境界にのみ置き、iOS は短期トークンで認証する。具体仕様は
  [`credential-strategy.md`](credential-strategy.md) 案 B と
  [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) をプラン生成向けに
  別 PR で具体化する。
- **iOS は引き続き `AITrainingPlanProviding` に依存する。** 実プロバイダは同プロトコルの
  別実装として追加し、`MockAITrainingPlanChatView` 以降の呼び出し側は変えない。
- **案 C（端末内モデル）は将来の評価対象として残す。** 着手前に PoC で品質を確認する。
- **`RuleBasedWeeklyPlanGenerator` は AI 無しで常に使えるようにする。** AI が無効・
  課金未設定・オフラインでもルールベースのプラン作成は従来どおり動く。
- **モックプロバイダ（`MockAITrainingPlanProvider`）はテスト / オフライン開発用に残す。**
  実プロバイダ追加後も `AITrainingPlanProviding` のモック実装は削除しない。
- **クレデンシャル戦略が確定するまで実 AI を実装しない。** 本ドキュメントと後続の
  バックエンド設計 PR（§9）が承認されるまで、プラン生成はモックのみで進める。

---

## 6. リクエスト / レスポンス契約（Request/Response Contract）

将来の実プロバイダ（案 B のバックエンド経由）が満たすべき**概念上の**入出力契約。
既存の値型（`AITrainingPlanRequest` / `AITrainingPlanResponse` /
`AITrainingSessionResponse`）の形を可能な限り再利用する。

**入力（`AITrainingPlanRequest` 相当）:**

- `userMessage`: 自由記述の相談文。**上限長を設ける**（例: 1,000 文字）。超過は
  クライアント / バックエンドで切り詰め、警告を返す。
- `goal` / `daysPerWeek` / `targetBodyParts` / `experienceLevel` / `preferredSplit`:
  任意の構造化ヒント。
- `availableMachineIds`: ユーザーが利用可能なローカルカタログのマシン id のみ。

**出力（`AITrainingPlanResponse` 相当 — 生・未検証）:**

- `title?` / `rationale?` / `warnings`
- `sessions`: 各 `AITrainingSessionResponse`（`title?` / `exerciseMachineIds` / `notes?`）

**制約と検証（バックエンドと正規化の両方で多層に課す）:**

- **`daysPerWeek` / セッション数を 1...6 にクランプ。**
- **1 セッションあたりの種目数に上限**（例: 8）を設ける。
- **`exerciseMachineIds` は既知のカタログ id のみ通す。** 未知の id は
  ドロップして警告（現行 `AITrainingPlanNormalizer` の挙動）。
- **空セッションはスキップ**して警告。
- **タイトル欠落は安全なフォールバック**（`Day N` / 目標ベース）。
- **空 / 不正な出力でもクラッシュしない**。空でも警告付き候補を返す。
- 出力はあくまで候補。`AITrainingPlanProviding` の戻り値は `AITrainingPlanResponse`
  のままで、実プロバイダでもモックでも同じ正規化器（`AITrainingPlanNormalizer`）を
  通して `WeeklyTrainingPlanCandidate` に変換する。

---

## 7. プライバシー / ロギング規則（Privacy & Logging Rules）

[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) に従う。追加で:

- **`userMessage` をログに残さない。** エラー時・テレメトリでも相談文を出力しない。
- **生のプロバイダレスポンスをログに残さない。**
- **生成ワークアウト詳細を個人的文脈と一緒にログしない。** 体重・健康履歴・位置などを
  生成リクエストに同梱しない。
- **相談文の送信はユーザーの明示操作後のみ。** 入力しただけでは送信しない。
- **バックグラウンド送信をしない。**
- **永続的なチャット履歴を持たない**（明示的に設計されるまで）。現状の候補は `@State`
  のみで、画面を離れれば消える。履歴保存が必要になったら別途スキーマ設計の検討が要る
  （本ドキュメント範囲外）。
- **ユーザー向けコピーがモック / 不確実性を明示する。** 現行の「これはモックAI相談です。
  実際のAI通信は行っていません。」の文言を、実 AI 化の際は適切な不確実性コピーへ
  差し替える。
- オプトインは細粒度。「AI プラン相談を有効にする」トグル（既定 OFF）に実 AI を
  ぶら下げる。

---

## 8. エラー / タイムアウト / レート制限（Errors, Timeout, Rate Limiting）

実クラウド AI は**従量課金**になりうる。乱用・暴走は直接コストになる。

- **型付きエラーを定義する**: timeout / network / provider / invalid response /
  rate limit。UI はそれぞれに適切な再試行コピーを出す。
- **ユーザー向け再試行コピー**を用意し、最終的に `RuleBasedWeeklyPlanGenerator` /
  手動編集へ着地できること。
- **キャンセル対応。** 生成中（`isGenerating`）にユーザーが離脱 / キャンセルできる。
- **リトライはユーザーの明示操作に限る。** 失敗時の自動再送をしない。
- **同一操作で推論を繰り返さない。** ユーザー操作 1 回 = 生成 1 回。
- **レート制限 / クォータはバックエンド側で**（案 B）。トークン単位のクォータを設ける。

各エラー状態で **`Routine` / `Step` を作らず**、次の行動（再試行 / ルールベース /
手動）を明示する。

---

## 9. 安全と検証（Safety & Validation）

- **`AITrainingPlanNormalizer` が最後の門番。** プロバイダ出力は必ずここを通す。
  バックエンドでの一次検証（§6）に加え、クライアントでも二重に検証する。
- **不正出力でクラッシュしない。** 正規化は純粋・total・例外なし。
- **空 / ジャンク出力は警告付き候補を返す。**
- **保存は明示確定が必須。** 現行の「候補 → レビュー → 確定 → 保存」境界を不変に保つ。
- **プロンプトインジェクション耐性**: プロバイダが返す自由テキスト（title / notes /
  rationale）は表示用テキストとしてのみ扱い、アプリ動作の指示として解釈しない。
  マシン選択は id 照合のみで決まり、自由テキストには影響されない。

---

## 10. 実装 PR の分割案（Future PR Breakdown）

各 PR は前段の境界を壊さないこと。`server/` に触れるのはバックエンド PR のみ。

| PR | 内容 | ネットワーク / 実 AI |
|---|---|---|
| **PR #77** | 本ドキュメント（AI プラン プロバイダ アーキテクチャ決定）＝本 PR | なし |
| **PR #78** | バックエンドプロキシのエンドポイント仕様（[`ai-training-plan-proxy-endpoint-spec.md`](ai-training-plan-proxy-endpoint-spec.md)）。**ドキュメントのみ** | なし |
| **PR (次)** | 必要ならバックエンド proxy / 短期トークン発行の実装（`server/`。別レビュー） | サーバ側のみ |
| **PR (次)** | iOS 実プロバイダクライアント（`AITrainingPlanProviding` の実装を追加）。設定トグルでガード、既定 OFF | あり（opt-in 時のみ） |
| **PR (次)** | UI のローディング / エラー / 再試行ハードニング | なし（クライアント） |
| **PR (次)** | QA・コスト・レート制限のハードニング | — |

---

## 11. 明示的な非ゴール（Non-Goals）

本 PR および本決定は次を**やらない / 認めない**:

- iOS クライアントへのプロバイダ API キー直接埋め込み。
- 相談文（`userMessage`）の隠れた送信。
- ルーティンの自動作成（確認なしの `Routine` / `Step` 生成）。
- 医療・栄養学的な診断やアドバイス。
- 生成プランの品質保証。
- 本 PR での実 AI 実装 / OpenAI 連携 / ネットワーク通信。
- 本 PR でのコード・スキーマ・`server/` 変更。

---

## 12. 実 AI 実装前の受け入れ基準（Acceptance Criteria）

実プロバイダ統合 PR に着手してよいのは、次がすべて満たされたとき:

- [ ] プロバイダ方式（§4 のいずれか。本命は案 B）が承認されている。
- [ ] クレデンシャル経路が承認されている（iOS は短期トークンまで）。
- [ ] クライアント側にシークレットが存在しない設計になっている。
- [ ] リクエスト/レスポンス制約（§6）が定義されている。
- [ ] プライバシー / ロギング規則（§7）が承認されている。
- [ ] エラー / タイムアウト / レート制限方針（§8）が定義されている。
- [ ] レビュー前確定なし（review-before-save）の境界が保たれている。
- [ ] テストが既定でモックを使う（ライブ AI を叩かない）。
- [ ] `RuleBasedWeeklyPlanGenerator` / 手動編集のフォールバックが引き続き利用できる。

1 つでも未達なら実 AI 実装は着手不可。それまでプラン生成はモックのみで進める。

---

## 関連ドキュメント

- [`gym-machine-catalog-and-plan-foundation.md`](gym-machine-catalog-and-plan-foundation.md)
  — マシンカタログ / 週次プラン候補フロー全体の設計。本ドキュメントはその「実 AI
  プロバイダ / クレデンシャル」の章を独立・詳細化したもの。
- [`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md) — 写真 AI の同型の
  意思決定。方式比較（案 A–D）・クレデンシャル結論を揃えている。
- [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) — AI の安全境界の鉄則。
  §3・§7 はこれをプラン生成 AI に適用したもの。
- [`credential-strategy.md`](credential-strategy.md) — クライアントに長期 API キーを
  置かない方針と、短期トークン方式（案 B）の比較。§4・§5 のクレデンシャル判断は
  これに従う。
- [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) — 短期デバイス
  スコープトークンのエンドポイント仕様。プラン生成が認証付きバックエンドを要する場合の
  参照元。
- [`ai-endpoint-integration-readiness.md`](ai-endpoint-integration-readiness.md) —
  endpoint provider を dev 経路へ接続する前の readiness checklist と local QA 手順。
- [`ai-endpoint-auth-token-strategy.md`](ai-endpoint-auth-token-strategy.md) — AI
  エンドポイント認証・型付きトークン戦略（スコープ・境界・エラー・責務分担）。実 AI /
  本番有効化の前提となる auth 設計。
