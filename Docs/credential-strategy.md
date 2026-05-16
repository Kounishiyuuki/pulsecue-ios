# PulseCue Credential Strategy for Gym Machine Import

> **本ドキュメントの目的**: iOS アプリから Cloudflare Worker
> (`pulsecue-gym-machine-api`) のジム機器インポートエンドポイントを
> 呼び出すために、どの credential 方式を採用するかを決めるための
> 比較・推奨資料。
> **実装変更は含まない**。意思決定が確定したあとに別 PR で実装する。

## 1. 現状

- Worker は既にデプロイ済みで、ヘルスチェックと `POST /api/gym-machines/import` が動作している（PR #17 / #18 / #19）。
- インポートエンドポイントは `Authorization: Bearer <PULSECUE_IMPORT_API_KEY>` で保護されており、Worker secret として設定済み。
- **iOS アプリは現時点で Worker を呼び出していない**。
  PR #20–#24 で実装されている My Gym フローは完全にオフラインファースト
  （手動マシン登録 + MapKit ベースのジム候補検索 + 部位選択 + ルーティン生成）。
- 本番 Worker の URL と API キーはリポジトリ・PR・ドキュメントいずれにも記録していない（コミット履歴を grep しても出てこない）。

## 2. 脅威モデル

- **公開アプリのバイナリに長期 API キーを埋め込んではいけない。**
  iOS の App Bundle は容易に展開・逆アセンブル可能であり、定数や Plist 経由で埋め込んだ Bearer キーはユーザーから抽出できる。
- **Keychain 単体では公開配布アプリの長期キー保護として十分ではない。**
  Keychain はオンデバイスの盗難・偶発的露出には強いが、最初にキーをアプリへ届ける段階（initial distribution）で必ず平文経路を通る。
- **共有 API キーが漏れると誰でもインポートエンドポイントを叩ける。**
  Worker は任意の外部 URL を fetch するため、レート制限・スコープ制御がないと:
  - 第三者の公式ページに対する不必要なトラフィック / 法的リスク
  - Worker のリクエスト/CPU クォータ消費
  - 将来的に課金が発生する第三者 API（Google Places 等）を足したときの請求リスク
- **デバッグ・社内配布と公開配布で安全レベルを混同しない。**
  TestFlight も含む内部配布は「漏れたら即時失効できる」前提なら長期キーでも回せるが、App Store 配布は別物として扱う。

## 3. 選択肢

各案について、実装労力・iOS 側作業・サーバー側作業・セキュリティ水準・App Store 適合性・運用コスト・採用すべき場面を整理する。

| | **A. DEBUG限定 Keychain 長期キー** | **B. 短期トークン + App Attest** | **C. Cloudflare Access** | **D. ユーザー認証ができるまで延期** |
|---|---|---|---|---|
| **実装労力** | 小 (1 PR) | 中 (iOS 1 PR + サーバー 1 PR) | 中〜大 (運用設計含む) | 0 |
| **iOS 側作業** | `KeychainCredentialProvider` + `#if DEBUG` 管理画面で開発者がキーを貼り付け | `LocationProvider` 風の `TokenProvider`。アプリ起動時に Device ID + `App Attest` アテステーションを送り短期トークン取得、Keychain 保存、期限切れで再取得 | Apple OIDC や magic link 等のサインインフロー (現在のアプリには未実装) | なし |
| **サーバー側作業** | 既存のままで OK | 新エンドポイント `POST /api/auth/import-token`。App Attest 検証 + 端末ID紐付け + 24h 程度の TTL | Cloudflare Access のポリシー設定 (Worker ルートに access policy を当てる) | なし |
| **セキュリティ水準** | 開発者ハンドキャリーで十分 / 公開には不適 | 最も実用的。キーは端末ローカル + 短期 + 失効可能 | 高 (アイデンティティプロバイダ前提) | リスクゼロ (機能なし) |
| **App Store 適合性** | 公開ビルドには含めない (`#if DEBUG`) ので可 | 適 | サインインの UX 次第 (現状 PulseCue にユーザー口座なし) | 適 |
| **運用コスト** | 鍵を開発端末に手作業で配るのみ | サーバー側にレート制限と監査ログを足す程度 | Access のサブスクリプション + 認証プロバイダ運用 | 0 |
| **いつ採るか** | 開発者単独・社内 TestFlight 検証段階 | App Store 公開時の本命 | PulseCue がユーザー口座 / 法人ライセンスを持ったとき | 当面、自動取り込みを諦めて手動フローのみで提供する場合 |

### 補足: 各案に追加で必要なこと

- **A**: Release ビルドで管理画面とプロバイダがコンパイルされないこと、`Authorization` ヘッダ構築コードが単一ファイルに閉じていること、ログ出力が一切ないことを CI ルールで保証する。
- **B**: 端末あたりの短期トークン発行頻度・失効リスト・App Attest が失敗したときのフォールバック (= 手動 My Gym フローに案内) を仕様化する。
- **C**: PulseCue がエンドユーザー直接利用のアプリである以上、Access の前段にユーザー側で何らかのサインイン UX を強制することになるため、現状の "登録なしで使える" 体験を維持できない可能性がある。社内ツール化したい場合のみ有効。
- **D**: 手動マシン選択 (PR #20) が「主導線」のままで十分という前提が必要。Today カード (PR #24) は既にそのモデルで動いている。

## 4. 推奨パス

- **開発フェーズ**: 案 **A** (DEBUG-only Keychain) は許容する。ただし条件:
  1. Release ビルドからは `#if DEBUG` で完全に除外。
  2. キーは個人開発端末の Keychain に手で投入する管理画面のみで導入。CI や ConfigurationFile では一切扱わない。
  3. `Authorization: Bearer ...` の組み立ては 1 ファイルに閉じ込め、`print` / OSLog / 例外メッセージにも載らないようコードレビュー時に確認する。
- **App Store 公開時の本命**: 案 **B** (短期トークン + App Attest)。
  - 長期共有キーは Worker 内部にしか存在せず、iOS には決して下りてこない構成。
  - 万一トークンが漏れても TTL で自然に失効する。
  - 既存 `LocationProvider` / `GymCandidateSearchService` と同じ protocol 駆動で iOS に組み込める。テスト容易性も維持できる。
- **`PULSECUE_IMPORT_API_KEY` は絶対に Release ビルドに含めない。**
  万一含めてしまった場合のリカバリ手順 (= `wrangler secret put` でローテーション) も別途運用ドキュメントに残す。
- **暫定提案**: ユーザー認証が当面の計画に入っていないなら、案 **D** (機能保留) を上回るのは案 **B** のみ。案 **C** は user-auth 実装と抱き合わせでないと意味が薄い。

## 5. 次の実装 PR (本ドキュメント merge 後)

候補:

- **PR-α: DEBUG-only import プロトタイプ** (案 **A**)
  - `GymMachineImportService` protocol + Worker 呼び出し実装
  - `KeychainCredentialProvider` + `#if DEBUG` 管理画面
  - `MachineImportReviewView` (候補レビュー UI)
  - Release ビルドに残らないようガード、ローカル動作確認まで

- **PR-β: 短期トークン発行のサーバー設計 PR** (案 **B**)
  - `Docs/credential-strategy.md` を更新して具体的なエンドポイント仕様を確定
  - `server/` に `POST /api/auth/import-token` を実装 (本ドキュメントの後続。本 PR には含めない)
  - iOS 側の `TokenProvider` 設計
  - App Attest の検証フローと失敗時 UX

### 推奨

**まず PR-β (案 B の設計 PR) を先に進める** ことを推奨する。

理由:

- PR-α (案 A) を先に書くと、その後 PR-β に乗り換えるとき `GymMachineImportService` のシグネチャ・エラー型・Keychain 取扱いを `TokenProvider` 経由に書き換える二重作業が発生する。
- いまユーザーは PulseCue に自動取り込みを **必要としていない** (My Gym 手動フローと Today クイック導線が機能している)。緊急性は無いので、手戻り少な目を優先するのが妥当。
- PR-β は **サーバー側の設計だけ確定させる軽い PR** から始められる。実装コードは別 PR。
- 案 **A** を本当に必要とするフェーズ (TestFlight QA で本物のジムページに対する精度確認をしたい等) になったら、その時点で短期トークン発行サーバーが既に存在していれば、開発者個人 1 名分の短期トークンを `wrangler secret put` で直接 Keychain に入れる運用で代用できる。`#if DEBUG` 管理画面すら不要になる。

## 6. スコープ外 (本ドキュメント・本 PR では扱わない)

- エンドユーザー向けユーザー口座 / サインアップ / ログイン UX
- 課金 / サブスクリプション
- OAuth / Apple Sign-In / ソーシャルログイン
- 本番 Worker への iOS 統合コード
- `server/` 内のコード変更
- `wrangler deploy` / `wrangler secret put` の実行
- secret ローテーション運用手順 (別ドキュメント化予定)
- 本番 Worker の URL / API キーの記載 (このリポジトリには一切載せない)

## 7. 今後のフォローアップ PR (参考)

ドキュメントだけでは実装は進まないので、決定後に次の PR を順に切る:

- **PR-α' (もし案 B 採用):** `Docs/credential-strategy.md` を更新し、短期トークン発行エンドポイントの仕様 (URL パス / リクエスト / レスポンス / TTL / エラー envelope) を確定する。コードなし。
- **PR-β: サーバー側トークン発行エンドポイント実装**。`server/src/routes/authImportToken.ts` 追加、App Attest 検証ライブラリ選定、ユニットテスト。
- **PR-γ: iOS 側 `TokenProvider` + `GymMachineImportService` 実装**。`#if DEBUG` ガードは不要 (短期トークンで本番ビルドにも安全に乗る)。
- **PR-δ: レート制限と監査ログ強化**。Cloudflare Worker 側で per-token quotas、`/health` 以外のリクエストを構造化ログに残す。

---

> **最後に**: 本ドキュメントはあくまで意思決定の出発点。
> 案 B か案 D かは、PulseCue が今後どのタイミングでユーザー口座を持つか、
> および自動取り込み機能をどの位優先するかで変わる。
> 採用案を確定したらこのファイルの「推奨」セクションに採用日付を追記し、
> 後続 PR で参照する。
