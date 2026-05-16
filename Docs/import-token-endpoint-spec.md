# PulseCue Import Token Endpoint Spec

> **本ドキュメントの目的**: 将来 iOS から
> `POST /api/gym-machines/import` を安全に呼び出すために、
> 短期トークンを発行する新エンドポイント
> `POST /api/auth/import-token` の仕様を**先に**確定させる。
> 実装は別 PR。
> 採用方針の背景は [`credential-strategy.md`](credential-strategy.md) を参照。

## 1. 目的 (Purpose)

- iOS アプリは長期 Worker secret (`PULSECUE_IMPORT_API_KEY`) を **絶対に** 端末・バイナリに保持しない。
- 代わりにサーバーからその場で発行する**短期・端末スコープのトークン**を Keychain に置き、`POST /api/gym-machines/import` を呼ぶときの `Authorization: Bearer` に使う。
- 端末ごと・期限付きなので、漏洩しても影響範囲が小さく、自然失効する。
- App Store 配布を視野に入れた唯一の現実的な方式 (案 B / `credential-strategy.md` §4)。

## 2. 現状 (Current state)

- Cloudflare Worker (`pulsecue-gym-machine-api`) は PR #17 / #18 / #19 でデプロイ済み。
- `POST /api/gym-machines/import` は `Authorization: Bearer <PULSECUE_IMPORT_API_KEY>` を要求する (PR #18)。
- iOS は現時点で Worker を一切呼び出していない。My Gym フロー (PR #20–#24) は完全にオフラインファースト。
- `PULSECUE_IMPORT_API_KEY` の実値および本番 Worker URL はこのリポジトリには記録していない。
- `credential-strategy.md` は公開リリース向けの本命として「短期デバイススコープトークン + App Attest」 (案 B) を推奨済み。

## 3. 提案エンドポイント (Proposed endpoint)

```
POST /api/auth/import-token
Content-Type: application/json
```

### 3.1 リクエストボディ (draft)

```json
{
  "deviceId": "<UUID 形式の端末識別子>",
  "appVersion": "<CFBundleShortVersionString + build, 例: 1.4.0 (210)>",
  "attestation": "<Base64 の App Attest assertion / 開発中はプレースホルダ文字列>"
}
```

- `deviceId`: 端末ローカルで生成・保持する UUID。`identifierForVendor` でも UUIDv4 でも可だが、サーバーから観測した重複が容易に解析できる程度に安定していること。
- `appVersion`: 互換性ガード用。サーバー側で旧バージョンを失効させるとき使う。
- `attestation`: 本番ビルドでは App Attest の assertion を Base64 でエンコード。開発・TestFlight 期間は緩い検証 (例えば固定の `dev-attestation`) に倒すことを許す (§6 参照)。

### 3.2 レスポンスボディ (draft, 200 OK)

```json
{
  "token": "<base64url, ~32B 程度のランダム or 署名付きペイロード>",
  "expiresAt": "<ISO 8601, 例: 2026-05-17T00:00:00Z>",
  "ttlSeconds": 86400
}
```

- `token` は **`PULSECUE_IMPORT_API_KEY` と必ず異なる文字列**。`Authorization: Bearer <token>` の形式で `POST /api/gym-machines/import` に直接送れる。
- `expiresAt` と `ttlSeconds` は冗長に併記する: iOS 側はどちらか片方を信頼すればよい。クロックずれ対策は §8.4 参照。

### 3.3 ヘッダ

- 認証ヘッダは **本エンドポイント自体には要求しない**。検証は `attestation` フィールドで行う (§6)。

## 4. トークンの性質 (Token rules)

トークンは以下を**必ず**満たす:

- **短期である**。TTL は MVP では 24 時間を上限とし、本番リリース時に再検討する (§10)。
- **インポートエンドポイントのみにスコープを限定する**。
  別のエンドポイントには使えない。署名付きトークンを採るならクレームに `scope: gym-machines:import` 相当を入れる。
- **期限切れ後は自動で無効**。サーバー側で `expiresAt` を強制チェックする。
- **`PULSECUE_IMPORT_API_KEY` と一致しない**。長期 secret は端末側へ一切渡らない。
- **どこにもログ出力しない**。発行直後のレスポンス本体を除き、サーバーログ・iOS の `OSLog` / `print` / クラッシュレポートのいずれにも残さない。
- **ソースコードに書かない**。`.env*` / `.dev.vars*` / Info.plist / Build Settings / GitHub Actions secrets いずれにも触れない。

## 5. App Attest / デバイス検証 (App Attest / device validation)

### 5.1 役割

- リクエスト元が**本物の PulseCue iOS アプリ**であることを保証する。
- 改造クライアントや別アプリからの呼び出しを排除する。
- 端末あたりの発行数をサーバー側でレート制限するための識別子 (`deviceId`) と紐付ける。

### 5.2 MVP / 開発フェーズの取り扱い

- 開発・TestFlight 期間中は緩い検証 (例: `attestation` がプレースホルダ文字列だったら警告ログだけ残して通す) を許容してよい。
- ただしその場合、トークン TTL は本番より短くする (例: 1 時間)。発行数も per-IP / per-deviceId で強めに絞る。
- **公開リリース前に、本物の App Attest 検証 (DCAppAttestService.attestKey → サーバー側のチャレンジ → assertion 検証) が動作することを必須とする**。

### 5.3 採用ライブラリの候補

- Workers 上で Apple の DeviceCheck/App Attest を検証するには、Apple の公開鍵 (App Attest CA) を fetch して JWS を verify するライブラリが必要。
- 既存の npm パッケージで決定打はないため、最小実装を `server/src/auth/appAttest.ts` (将来) に置く想定。本 PR ではコードは追加しない。

## 6. エラー envelope (Error envelope)

既存 Worker のエラー形式と揃える:

```json
{
  "error": {
    "code": "<machine-readable code>",
    "message": "<human-readable Japanese description>"
  }
}
```

### 6.1 エラーコード (draft)

| code | HTTP | 説明 |
|---|---|---|
| `invalid_body` | 400 | リクエスト JSON のパース失敗 / 必須フィールド欠落 / 型不正 |
| `invalid_attestation` | 401 | `attestation` の検証に失敗 (本番) または開発モードでもプレースホルダ要件を満たさない |
| `rate_limited` | 429 | 端末・IP あたりの発行頻度上限を超過 |
| `internal_error` | 500 | 想定外のサーバー側失敗 |

### 6.2 注意

- `message` はクライアントに表示する想定なので、トークン値・内部スタックトレース・他端末の `deviceId` を絶対に含めない。
- 401 は **トークン検証失敗ではなく端末検証失敗を意味する**。トークンそのものの 401 は `POST /api/gym-machines/import` 側で起きる (§8.3)。

## 7. iOS クライアントの期待動作 (iOS client expectations)

### 7.1 役割分担

- 新しい `TokenProvider` protocol が token のライフサイクルを管理する。
- `GymMachineImportService` は **`TokenProvider` 経由でしか** トークンに触らない。Keychain に直接アクセスしない。
- `TokenProvider` の実装は Keychain にトークンと `expiresAt` を保存し、有効なものがあればそれを返す。期限切れ / 未取得時のみ `POST /api/auth/import-token` を呼ぶ。

### 7.2 ヘッダの組み立て

`GymMachineImportService` は次のヘッダで `POST /api/gym-machines/import` を呼ぶ:

```
Authorization: Bearer <short-lived-token>
Content-Type: application/json
User-Agent: PulseCueImportBot/0.1 (...)
```

### 7.3 401 のリカバリ

- インポートエンドポイントから 401 が返った場合、**1 度だけ**トークン再取得 → 同じ import リクエストをリトライする。
- 2 度目も 401 なら諦めてエラー UI を出す (ループ防止)。

### 7.4 クロック対策

- `expiresAt` を信頼するとき、安全マージンとして 30 秒前にローカル期限を切る。

## 8. セキュリティノート (Security notes)

- 本番 Worker secret (`PULSECUE_IMPORT_API_KEY`) を **App ビルドのどこにも** 埋め込まない。
- トークン値を `print` / `OSLog` / クラッシュレポートに**一切**出さない。`URLRequest` のヘッダをまるごとログ出力するパターンに注意。
- `POST /api/auth/import-token` 側でレート制限する: per-IP, per-`deviceId`。
- `POST /api/gym-machines/import` 側でもレート制限する: per-token (例: 60 req / 24h)。
- 監査ログは `deviceId` (もしくはその hash) + `appVersion` + timestamp + 結果コードのみ。トークン値や `attestation` 本体は載せない。
- secret ローテーション運用 (e.g. `PULSECUE_IMPORT_API_KEY` のローテーション、トークン署名鍵のローテーション) は別ドキュメント化予定。

## 9. オープンクエスチョン (Open questions)

1. **トークン TTL**: 24 時間が妥当か。短すぎると体験が悪く、長すぎると漏洩リスクが伸びる。
2. **App Attest ロールアウトのタイミング**: TestFlight に最初に乗せるとき緩い検証で出すのか、最初から本物を要求するのか。
3. **TestFlight ビルドで緩い検証を許すか**: 許す場合、緩い検証で発行されたトークンが Release Worker を叩けないようにスコープを分けるか。
4. **レート制限の具体値**: per-`deviceId` の発行頻度、per-token の import 呼び出し回数。
5. **トークンの署名形式**: 単なるランダム文字列で十分か、JWT/署名付きペイロード化してサーバー側のセッション保持を不要にするか。
6. **`deviceId` の生成元**: `identifierForVendor` か UUIDv4 を Keychain に保存か。前者はアプリ再インストール後の挙動が異なる。
7. **iOS で TokenProvider が失敗したときの UX**: My Gym 手動フロー (PR #20) を強調する案内で OK か。

## 10. 後続 PR (Follow-up PRs)

依存順:

1. **(本 PR)** `Docs/import-token-endpoint-spec.md` 確定。
2. **PR-β1: サーバー側 `POST /api/auth/import-token` 実装**。`server/src/routes/authImportToken.ts` 追加。MVP は緩い `attestation` 検証で OK、ただしトークン TTL を 1 時間に絞る。ユニットテスト含む。
3. **PR-β2: App Attest 本検証**。Apple の root と中間 cert を fetch する `server/src/auth/appAttest.ts`、challenge 発行 + assertion verify。`server/.dev.vars.example` に開発用フラグ追加。
4. **PR-γ1: iOS `TokenProvider` + `KeychainTokenStore`**。`#if DEBUG` ガードなし (短期トークンは Release でも安全に扱える)。
5. **PR-γ2: iOS `GymMachineImportService`**。`TokenProvider` 経由で Authorization を組み立て、`POST /api/gym-machines/import` を呼ぶ。401 リカバリ・タイムアウト・エラー envelope のデコードまで。
6. **PR-γ3: import レビュー UI**。`MachineImportReviewView` で候補リスト + 警告 + 「マシン情報に取り込む」CTA。
7. **PR-δ: レート制限と監査ログ強化**。Cloudflare Worker 側で per-token quotas、構造化ログ。
8. **PR-ε: secret ローテーション運用 runbook**。`Docs/credential-runbook.md` 新設、コードなし。

## 11. スコープ外 (Out of scope, 本 PR では扱わない)

- サーバー実装。
- iOS 実装 (`TokenProvider` / `GymMachineImportService` / `KeychainTokenStore` / UI)。
- SwiftData スキーマ変更。
- `wrangler deploy` / `wrangler secret put` の実行。
- secret ローテーション運用手順。
- 本番 Worker の URL / API キーの記載 (このリポジトリには一切載せない)。
- ユーザー口座 / OAuth / Apple Sign-In / 課金。

---

> **更新ルール**: 本仕様は §3 / §4 / §6 の draft 部分が後続 PR で固まったら必要に応じて改訂する。
> 大きな仕様変更を加えるときは、本ファイルの末尾に変更履歴を追記して理由を残す。
