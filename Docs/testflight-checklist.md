# TestFlight 初回ビルド チェックリスト

PulseCue の最初の TestFlight ビルド提出手順。**リポジトリで検証可能な項目**と**手動作業**を分離する。詳細な現況は `app-store-readiness.md`、アーカイブ手順は `release-process.md` を参照。

判定: [ ] 未 / [x] 済 / (手動) 人手 / (外部) 外部設定 / (未検証) 本環境で確認不可

## A. リポジトリ側（自動/コマンドで検証可能）

- [x] `main` がクリーン・`origin/main` と一致（ahead/behind 0/0）
- [x] Bundle ID `com.kounishiyuuki.pulsecue`
- [x] Display Name `PulseCue`
- [x] Deployment Target iOS 17.0 / iPhone のみ / Portrait のみ
- [x] `PrivacyInfo.xcprivacy` 同梱・valid（UserDefaults `CA92.1`）
- [x] App Icon（1024 + Dark + Tinted）同梱
- [x] Sign in with Apple entitlement 有効 / HealthKit entitlement 有効
- [ ] **`PulseCueAPIBaseURL` が本番 HTTPS URL**（現 `main` は placeholder `https://YOUR_PULSECUE_API_HOST`）(手動・P0)
- [ ] **`GIDServerClientID` が本番 Web client ID**（現 `main` は placeholder）、server の `GOOGLE_AUDIENCE` と一致 (手動・P0)
- [x] `PrivacyInfo.xcprivacy` に Email Address / User ID（linked・tracking なし・App 機能）を宣言
- [x] DEBUG QA ルート/引数が Release バイナリに不在（`strings` 実測）
- [x] シークレット/`workers.dev` ハードコードなし（本番 URL は Info.plist で設定、secret は持たない）
- [x] Debug / Release ビルド成功（`CODE_SIGNING_ALLOWED=NO`）
- [x] 全 unit / UI テスト green（新規 skip なし）
- [x] `./Scripts/verify-release-readiness.sh` が pass
- [ ] **build 番号のインクリメント**（TestFlight は build 番号の一意性が必須。2回目以降は `CURRENT_PROJECT_VERSION` を上げる）(手動/都度)

## B. アーカイブ・署名・アップロード（手動・実機/Xcode）

- [ ] Xcode: Generic iOS Device / 実機で **Product > Archive** (手動)(未検証)
- [ ] Automatic signing で Distribution プロファイル解決 (手動)(外部)
- [ ] Organizer から **Distribute App > TestFlight (App Store Connect)** (手動)(未検証)
- [ ] アップロード後の **processing 完了**待ち (手動)
- [ ] Export Compliance（暗号化）回答：標準の HTTPS のみ・独自暗号なし → 通常「No」/ 該当免除 (手動・要確認)

## B2. サーバ（手動・外部）

- [ ] `pulsecue-api` を deploy（`server/wrangler.api.jsonc` の D1 `database_id` は現在 placeholder）。D1 migrations 0001–0006 適用 (外部)
- [ ] Worker vars/secrets を設定 (外部): `APPLE_AUDIENCE` / `GOOGLE_AUDIENCE` / `APPLE_CLIENT_ID` / `APPLE_TEAM_ID` / `APPLE_KEY_ID` / `APPLE_PRIVATE_KEY` / `APPLE_TOKEN_ENCRYPTION_KEY`(+`_VERSION`)。一覧は `server/src/api/types.ts`
- [ ] 本番 URL で `/v1/auth/apple` `/v1/auth/google` `/v1/me` `DELETE /v1/me` を実機で確認 (手動)
- [ ] Cron（15分）が動いていること（削除の revoke 再試行・期限切れ session/nonce 掃除） (外部)

## C. App Store Connect（手動）

- [ ] App レコード作成（Bundle ID 紐付け） (手動)(外部)
- [ ] テスト情報（ベータ App 説明・連絡先・フィードバックメール） (手動)
- [ ] 内部テスターグループ作成・追加 (手動)
- [ ] ビルドを内部テスターに割当 (手動)
- [ ] ビルドノート記入（下記テンプレ参照） (手動)

## D. ビルドノート テンプレート（内部テスター向け）

```
PulseCue v1.0 (build N) — 初回内部テスト

含まれるもの:
- ローカルファーストの MVP（今日 / ワークアウト / ランナー / 履歴 / My Gym / プラン候補 / フォームガイド）
- PulseCue アカウント（Apple / Google でサインイン・任意。未ログインでも全機能利用可）
- アカウントのログアウト・アプリ内削除

既知の制限:
- トレーニング記録などはこの端末に保存され、クラウド同期・バックアップはまだ行わない
- AI プラン相談は端末内のモック（実 AI には接続しない）
- フォームガイド 3D は改善作業中（別PR）

確認してほしい点:
- 新規インストール後のオンボーディング→ゲスト利用
- Apple / Google サインイン → アプリ再起動後もサインイン維持 → ログアウト
- 機内モードで起動しても記録機能が使えること
- アカウント削除後、サインイン前の状態に戻ること
- ワークアウト開始→休憩→完了→履歴表示
- バックグラウンド/復帰後のランナー継続
- ダーク/ライト、大きい文字サイズ
```

## E. 既知の制限・データ互換

- ワークアウト等のデータは端末内 SwiftData（Schema V9・移行チェーン V1→V9）。クラウド同期・バックアップなし。アカウント情報（user ID・メール・セッション）のみサーバに保存。
- 初回インストールは空状態→オンボーディング。既存データからのアップグレードは移行プランで処理（**実機での upgrade テストは `device-qa-matrix.md` 参照・未実施**）。

## F. ロールバック

- TestFlight は前ビルドを内部テスターに再割当可能。詳細は `release-process.md`。
- アプリは「前 build を配布」でロールバック可能。ただし API はサーバ側にあるため、API の互換性を壊す server deploy は app のロールバックでは戻らない（server は別途ロールバック）。

> 注意: 本チェックリストの B/C は**本環境で未実施**。アーカイブ/アップロードの成功は実施後に各自で確認すること（虚偽の成功主張はしない）。
