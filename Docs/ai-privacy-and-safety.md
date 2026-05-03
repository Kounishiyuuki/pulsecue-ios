# AI / Meal Estimation の安全境界

PulseCue の AI 関連機能は、**「ユーザーが明示的に opt-in した一回のリクエストに限り、ユーザー自身がレビューしたデータだけを送り、結果は確認後にしか保存しない」** という方針で設計しています。

## 鉄則

1. **ローカルが真実**：DayLog / Routine / Step / Session / StepResult はすべて手元のデバイスに留まる。AI レスポンスを SwiftData に書き込む前には、必ずユーザー確認を挟む。
2. **暗黙送信ゼロ**：AI サービスへ送るデータは、その画面のその操作で送ることに同意した分のみ。バックグラウンドで履歴・体重・睡眠などを送らない。
3. **API キーをアプリに同梱しない**：本番のキーは Apple の Cloud-side proxy or `xcconfig`（git 管理外）で扱う。本リポジトリにコミットしない。
4. **オフラインで降格**：AI が無効 or ネットワーク不通でも、Runner / DayLog の操作はすべて従来通り使える。
5. **オプトインは細粒度**：「AI コーチを有効にする」と「食事推定を有効にする」は別の設定とし、デフォルトは両方 OFF。

## コード上の表現

`Pulse Cue/Services/AICoachStub.swift` で以下を提供：

- `AICoaching` / `MealCalorieEstimating` プロトコル
- それぞれの `Disabled*` 実装（常に `.disabled` を返す）
- `AIServicesProvider`：差し替え点。本番実装が出来るまでは `Disabled*` のまま
- `UserConfirmed<Value>`：AI が生成した値を SwiftData に書き込む前にラップする型
- `applyConfirmedMealEstimate(_:to:)`：`UserConfirmed<MealEstimate>` でない限り DayLog の `intakeCalories` を書き換えない

UI 層は以下のフローを守る：

```
[user opt-in] -> AIServicesProvider.* -> show preview UI ->
   user reviews -> wrap in UserConfirmed -> mutate model
```

`UserConfirmed` でラップせずに DayLog や Routine を直接書き換える経路は許可しない。

## 実装着手時にやること

- [ ] Settings に「AI コーチを有効にする」「食事カロリー推定を有効にする」トグル（既存の `SettingsStore` に追加）
- [ ] それぞれの実装を `AIServicesProvider` に差し込む
- [ ] API キーは `xcconfig` で `BuildSettings` に渡し、`.gitignore` に追加
- [ ] 食事推定はカメラ画像 / 文字 / バーコードの 3 ソースを順に対応（最初は `.text`）
- [ ] AI コーチは「直近 N セッションのサマリーのみ送信し、ルーティン名は仮名化」というプリプロセスを追加
- [ ] テレメトリ最小化：エラー時もログにユーザー入力を含めない

## やらないこと

- ユーザー操作なしの自動同期 / 自動推定
- 履歴の一括送信
- DayLog の自動上書き
- API キーや個人情報のリポジトリ同梱
