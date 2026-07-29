# リリース手順 / ロールバック

PulseCue のビルド番号運用・アーカイブ・アップロード・ロールバックの手順。実装フェーズは「ローカルファースト・実API/実認証なし」。

## 1. バージョン / ビルド番号

- `MARKETING_VERSION`（例 `1.0`）= ユーザー可視の公開バージョン。
- `CURRENT_PROJECT_VERSION`（例 `1`）= build 番号。**TestFlight/App Store は同一バージョン内で build 番号の一意・単調増加が必須**。
- 新しい TestFlight ビルドを上げるたびに `CURRENT_PROJECT_VERSION` を +1（App/Tests/UITests の全ターゲットで揃える）。
- 公開機能を増やす節目で `MARKETING_VERSION` を上げる（例 1.0 → 1.1）。

## 2. 事前チェック（自動）

```
./Scripts/verify-release-readiness.sh          # 高速チェック
./Scripts/verify-release-readiness.sh --full   # + Debug/Release ビルド
```

さらに手動で:
```
xcodebuild test -project "Pulse Cue.xcodeproj" -scheme "Pulse Cue" \
  -destination 'platform=iOS Simulator,name=<sim>' CODE_SIGNING_ALLOWED=NO
```
全 unit/UI が green・新規 skip なしを確認。

## 3. アーカイブ〜アップロード（手動・Xcode）

1. `main` をクリーンにし、build 番号をインクリメント。
2. 実機/Generic iOS Device を選択。
3. **Product > Archive**（Release 構成・Automatic signing）。
4. Organizer > **Distribute App > TestFlight (App Store Connect)**。
5. Export Compliance: 標準 HTTPS のみ・独自暗号なし（該当免除の想定／回答は都度確認）。
6. アップロード後、App Store Connect で **processing 完了**を待つ。

> 本手順は Xcode/実機・Apple Developer アカウントを要し、本リポジトリ環境では**実行・検証不可**。成功は実施者が各自確認する。

## 4. 内部テスト配信

1. App Store Connect > TestFlight > 内部テスターグループにビルドを割当。
2. ビルドノート記入（`testflight-checklist.md` テンプレ）。
3. `device-qa-matrix.md` を実機で消化。

## 5. App Store 提出（TestFlight 検証後）

1. App 情報・価格・App Privacy 回答（カメラ/位置/OpenFoodFacts 通信を反映・トラッキングなし）。
2. スクリーンショット・説明・キーワード・サポートURL・プライバシーポリシーURL。
3. 年齢レーティング。
4. 審査提出。

## 6. ロールバック

サーバ/リモート構成・機能フラグを持たないため、ロールバックは配布の差し替えで完結:

- **TestFlight**: 問題ビルドの配布を停止し、直前の安定 build を内部テスターへ再割当。
- **App Store（審査前/却下）**: ビルドを外し、修正 build を上げ直す。
- **App Store（公開後）**: 前バージョンの再公開は不可のため、修正版を新 build として速やかに提出（Expedited Review 検討）。「フェーズ公開」を使っている場合は公開を一時停止。
- データ: SwiftData はローカルのみ・破壊的移行は行わない方針。ロールバックでユーザーデータ損失が起きない設計を維持（スキーマ後方互換を崩す変更は別途レビュー）。

## 7. 変更してはいけない境界（リリース作業時）

- SwiftData スキーマ / 移行 / 永続化セマンティクス
- Runner 状態機械 / planner 生成規則
- 認証プロバイダ / バックエンド / ネットワークエンドポイント / トークン保存 / Keychain
- Form Guide 3D ジオメトリ / RealityKit パイプライン（別PR）

リリース準備の変更は**メタデータ・ビルド構成・DEBUG分離・ドキュメント・テスト**に限定する。
