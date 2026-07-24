# 3D フォームガイド MVP（RealityKit）

> 対象: `Pulse Cue/FormGuide3D/*` と `ExerciseGuideView` / Runner / preview 連携。
> 本機能は**動きの参考**であり、正しいフォームや安全・怪我防止を保証するものではない。

## アーキテクチャ概要

- **描画**: RealityKit の `ARView`(`cameraMode: .nonAR`, `automaticallyConfigureSession = false`)。
  純粋な仮想 3D シーンで、**ARSession を開始せず、カメラ権限も要求しない**。
- **iOS 17 互換**: deployment target は iOS 17.0 のまま。使用するメッシュは box / sphere
  のみ（iOS 18 の cylinder/cone/capsule は使わない）。実際に iOS 17 ターゲットで
  ビルドが通ることを確認済み。
- **手続き的マネキン**: 外部 3D アセットを一切同梱せず、`MannequinFactory` が
  `MannequinSkeleton`（純粋な骨格定義）から角丸 box + sphere の関節付き人体を生成。
  全種目で 1 つの階層を再利用する。
- **モーション**: `ExerciseMotionProfile` / `ExerciseMotionLibrary`（非永続・静的・
  ネットワーク非依存）が、安定 `ExerciseID` をキーに start→peak→start の関節キー
  フレームを定義。`ExerciseMotionEngine` が正規化進捗 0...1 を補間（RealityKit 非依存で
  ユニットテスト可能）。`ExerciseGuide.animationAssetId` は誤用せず nil のまま。
- **単一アニメクロック**: `Exercise3DSceneController` が `SceneEvents.Update` を 1 本だけ
  購読して進捗を進め、各関節 entity の `orientation` を更新。ジョイントごとの Timer は
  使わない。dismiss で購読解除・シーン解放。

## ExerciseID 連携

`Step.exerciseId`(V4 永続化) → `ExerciseID` → `ExerciseLibrary` / `FormGuideLibrary`
/ `ExerciseMotionLibrary`。10 種目のガイドに 1:1 でモーションプロファイルが対応。
それ以外の種目はテキストのみ（3D なし）で従来どおり動作する。

## Runner 連携

Runner の現在ステップに「フォームを見る」を表示する条件は
`Step.hasResolvableGuide`（= 永続 `exerciseId` が既知種目のガイドに解決できる）**のみ**。
title・器具表示名・カスタムマシン名からは一切推測しない。ガイド表示は観測的で、
ワークアウト状態（現在ステップ / セット・レップ進捗 / 休憩タイマー / セッション /
StepResult）を変更しない。

## Reduce Motion / アクセシビリティ

- `accessibilityReduceMotion == true` の場合、**自動連続再生をオフ**にして静的な
  デモポーズ（peak）を表示し、ユーザーが再生ボタンで任意に動かせる。バッジで明示。
- テキストガイドが常に権威ある代替手段。3D 初期化失敗時はテキストは表示され続け、
  簡潔な非ブロッキングのフォールバック文言を出す（クラッシュ・dismiss 阻害なし）。
- 再生 / 速度 / 視点 / リセットの各操作にアクセシビリティラベルを付与。アイコンのみの
  無ラベル操作なし。色のみの状態表現をしない。

## オフライン / サイズ / 性能

- ネットワーク・リモートアセット・外部パッケージなし。完全オフライン。
- すべて手続き的生成のためバイナリアセット追加はゼロ（メッシュ/マテリアルを再利用）。
- 同時に動く 3D シーンは 1 つのみ。dismiss で購読停止・エンティティ解放。

## 既知の制約（シミュレータ）

シミュレータの Metal は RealityKit の programmable blending / shadow 技法を完全には
サポートせず、`makeRenderPipelineState failed` 等の警告が出る（実機では発生しない）。
このため 3D の忠実な**目視確認は実機推奨**。モーションの方向的正しさは forward
kinematics のユニットテストで担保している。

## 将来の差し替えシーム

`ExerciseID` / `ExerciseGuide` / `ExerciseMotionProfile`（identity と関節ポーズ）を
renderer から分離しているため、将来の高品質共通リグ USDF を導入する際も、
`ExerciseGuideView` / Runner / preview 連携やモーション identity を書き換えずに
`MannequinFactory` 相当の描画層だけ差し替えられる。

## 明示的に対象外

- カメラによるフォーム解析 / 姿勢推定 / ARKit body tracking / rep カウント / AI 採点は
  本 PR に含めない（将来の独立機能）。
- SwiftData スキーマ（V4）・migration の変更なし。
