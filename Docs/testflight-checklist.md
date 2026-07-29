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
- [x] Sign in with Apple entitlement 有効
- [x] DEBUG QA ルート/引数が Release バイナリに不在（`strings` 実測）
- [x] シークレット/`workers.dev`/本番エンドポイントなし
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
- Sign in with Apple（任意・未ログインでも全機能利用可）

既知の制限:
- Google ログインは未設定（ボタンは無効表示）
- 実 AI / 実 API / サーバ同期・バックアップは未実装（データは端末内のみ）
- フォームガイド 3D は改善作業中（別PR）

確認してほしい点:
- 新規インストール後のオンボーディング→ゲスト利用
- ワークアウト開始→休憩→完了→履歴表示
- バックグラウンド/復帰後のランナー継続
- ダーク/ライト、大きい文字サイズ
```

## E. 既知の制限・データ互換

- データは端末内 SwiftData（Schema V4・移行チェーン V1→V4）。同期・バックアップなし。
- 初回インストールは空状態→オンボーディング。既存データからのアップグレードは移行プランで処理（**実機での upgrade テストは `device-qa-matrix.md` 参照・未実施**）。

## F. ロールバック

- TestFlight は前ビルドを内部テスターに再割当可能。詳細は `release-process.md`。
- サーバ/リモート構成を持たないため、ロールバックは「前 build を配布」で完結。

> 注意: 本チェックリストの B/C は**本環境で未実施**。アーカイブ/アップロードの成功は実施後に各自で確認すること（虚偽の成功主張はしない）。
