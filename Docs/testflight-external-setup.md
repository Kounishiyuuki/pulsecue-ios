# TestFlight 外部設定手順（Apple / Google）

TestFlight 提出前に、リポジトリ外（Apple Developer Portal / Google Cloud Console）で必要な
外部設定をまとめる。`Docs/testflight-readiness-baseline.md` §3.3 を補完する実作業ガイド。

> このドキュメントは手順のみを記載する。**secret / token / API key / バックエンド資格情報は
> 一切ここに書かない・アプリにも追加しない。** アプリはローカルファースト維持。

---

## 1. Apple Developer Portal 設定（Sign in with Apple）

- **App ID:** `com.kounishiyuuki.pulsecue`
- **有効化する Capability:** `Sign in with Apple`
- **理由:** アプリの entitlements に以下が含まれるため。

  ```
  com.apple.developer.applesignin = ["Default"]
  ```

- **手順（Developer Portal）:**
  1. Certificates, Identifiers & Profiles → Identifiers で App ID `com.kounishiyuuki.pulsecue` を開く。
  2. Capabilities 一覧で **Sign in with Apple** を有効化して保存。
  3. 必要に応じて Provisioning Profile を再生成（Automatic Signing の場合は Xcode が自動更新）。

- **注意:**
  - ローカルの **Simulator ビルドは Portal 設定なしでも通る**ことがある。
  - 一方で **実機ビルド / Archive / TestFlight 署名**では、App ID 側で
    `Sign in with Apple` が有効でないと署名・動作に失敗する場合がある。提出前に必ず有効化する。
  - **secret / token は追加しない。** 設定は Portal 側の Capability 有効化のみ。

### 1.1 Personal（無料）チーム制約と Apple Developer Program（重要）

Archive 検証で判明した確定的な制約。**アプリコードのブロッカーではなく、Apple アカウント種別の制約。**

- **Personal（無料）開発チームでは Archive できない。**
  本アプリは `com.apple.developer.applesignin` entitlement を持つため、**Personal/無料の Apple
  開発チームでは Sign in with Apple Capability を含むプロビジョニングプロファイルを作成できず、
  Archive 署名が失敗する。** 実際のエラー例:

  ```
  Cannot create a iOS App Development provisioning profile for
  "com.kounishiyuuki.pulsecue". Personal development teams do not support
  the Sign In with Apple capability.
  ```

- **有料 Apple Developer Program メンバーシップが必須。**
  Sign in with Apple を含む状態での **Archive / TestFlight 配布には、有料の
  Apple Developer Program（個人 or 組織の正式チーム）への加入が必要。** TestFlight
  アップロード自体も有料メンバーシップが前提。

- **加入後の手順（コード変更なしで進められる）:**
  1. Apple Developer Program に加入し、正式（有料）チームを取得する。
  2. Xcode の Signing & Capabilities で、対象ターゲットの Team を**正式（有料）チーム**に切り替える。
  3. App ID `com.kounishiyuuki.pulsecue` で `Sign in with Apple` Capability を有効化（§1）。
  4. Automatic Signing でプロビジョニングプロファイルを再生成／更新させる
     （`-allowProvisioningUpdates` でも可）。
  5. Archive 検証を再実行する（成功すれば TestFlight アップロードへ進める）。

- **entitlement 削除は既定の解決策にしない。**
  `com.apple.developer.applesignin` を外せば Personal チームでも開発ビルドは可能になるが、
  これは **ローカル開発時の一時的な回避策**に限る。Sign in with Apple は本アプリの機能であり、
  **リリース経路では entitlement を維持したまま有料チームで署名する**のが正しい。回避目的での
  恒久的な entitlement 削除は行わない。

---

## 2. Google Cloud OAuth iOS クライアント設定

- **作成するもの:** Google Cloud Console で **OAuth クライアント（種類: iOS）** を作成。
- **Bundle ID:** `com.kounishiyuuki.pulsecue`
- **取得する値:**
  - iOS クライアント ID（`<...>.apps.googleusercontent.com`）
  - reversed client ID / URL スキーム（`com.googleusercontent.apps.<...>`）

- **手順（Google Cloud Console）:**
  1. APIs & Services → Credentials → Create Credentials → OAuth client ID。
  2. Application type で **iOS** を選択。
  3. Bundle ID に `com.kounishiyuuki.pulsecue` を入力して作成。
  4. 発行された **iOS クライアント ID** と **reversed client ID** を控える。

- **アプリに追加してはいけないもの（重要）:**
  - **サーバー用 client secret は追加しない。**
  - **API key は追加しない。**
  - **バックエンド資格情報は追加しない。**
  - アプリが持つのは iOS クライアント ID と URL スキームのみ（いずれも非機密）。

---

## 3. Info.plist プレースホルダの置換

`Pulse Cue/Info.plist` の以下 **2 値のみ**を、§2 で取得した実値に置換する。

| キー | 現在のプレースホルダ | 置換後 |
|---|---|---|
| `GIDClientID` | `YOUR_IOS_CLIENT_ID.apps.googleusercontent.com` | `<実 iOS クライアント ID>.apps.googleusercontent.com` |
| `CFBundleURLTypes` → `CFBundleURLSchemes` | `com.googleusercontent.apps.YOUR_IOS_CLIENT_ID` | `com.googleusercontent.apps.<実 reversed client ID>` |

- **置換が必要なのはこの 2 値のみ。** 他の Info.plist 値は変更不要。
- **コード変更は不要。** 正しい値を入れれば `GoogleSignInConfig.isConfigured` が `true` になり、
  Google ログインが自動的に有効化される。
- **正しい値が入るまで** は Google Sign-In は無効のまま（ボタンは disabled、
  「設定準備中」相当のメッセージを表示）。プレースホルダ状態では
  **偽のサインイン済み状態（fake signed-in state）を作らない。**

---

## 4. TestFlight 提出前チェックリスト

### 4.1 外部設定
- [ ] Apple Developer Portal で App ID の `Sign in with Apple` Capability を有効化（§1）
- [ ] Google OAuth 値は次のいずれか:
  - [ ] プレースホルダのまま（Google ログインは無効＝意図どおり）、または
  - [ ] 実値に置換済み（§2・§3）かつ実機で手動テスト済み

### 4.2 ビルド / テスト
- [ ] Debug build 成功
- [ ] Release build 成功
- [ ] Unit tests 成功
- [ ] UI tests 成功（実施できる場合）
- [ ] Release leakage scan を確認（`127.0.0.1` / `8787` / fake token / `workers.dev` 等のアプリ固有リーク 0 件）

### 4.3 プロジェクト設定
- [ ] `PrivacyInfo.xcprivacy` が同梱されている
- [ ] Bundle ID = `com.kounishiyuuki.pulsecue`
- [ ] iPhone-only（`TARGETED_DEVICE_FAMILY = 1`）
- [ ] Portrait-only

### 4.4 手動 QA（実機 / Simulator）
- [ ] Sign in with Apple を手動テスト（可能なら）
- [ ] Google Sign-In を手動テスト（**実 OAuth 値を設定した場合のみ**）
- [ ] ゲストモードを手動テスト
- [ ] オンボーディングを手動テスト
- [ ] ログイン / アカウント画面を手動テスト
- [ ] プロフィール / ジム設定を手動テスト

> 認証準備フェーズ（オンボーディング / ログイン / アカウント / プロフィール・ジム設定）の
> 詳細な手動 QA 項目は `Docs/manual-qa-checklist.md` の「認証準備フェーズ」節を参照。

---

## 5. Release リーク検査メモ（参考・軽量手順）

DEBUG 限定の QA 文字列や本番 URL/トークンが Release バイナリに混入していないことを確認する
軽量手順。**secret / token は記載しない。** スキャン語にヒットしないことが期待値。

1. Release ビルド成果物の `.app` を特定し、メインバイナリに対して `strings` で確認する。
2. 期待値: 以下のアプリ固有リスク語はすべて **0 件**。
   - `OPENAI_API_KEY` / `sk-` / `8787` / `workers.dev` / `.workers.dev`
   - `fake-valid` / `fake-expired` / `fake-wrong-scope` / `DebugFakeToken`
   - `AI endpoint QA` / `開発者ツール` / `FAKE TOKEN`
3. 解釈の注意:
   - `127.0.0.1` / `id_token` / `access_token` / `refresh_token` / `client_secret` / `Keychain` 等が
     検出されても、それらは **GoogleSignIn / AppAuth / GTMAppAuth SDK のメタデータ**であり、
     アプリ所有コードのトークン保存ではない（`8787` が 0 件なら DEBUG ループバックではない）。
   - 判断に迷う場合はソース grep で、アプリ所有コードが token/code/user ID を保存・ログ・
     `AuthSessionStore` へ受け渡ししていないことを併せて確認する。

> 関連ドキュメント:
> - TestFlight 提出ベースライン（プロジェクト設定 / App Privacy 回答）: `Docs/testflight-readiness-baseline.md`
> - 手動 QA チェックリスト: `Docs/manual-qa-checklist.md`
