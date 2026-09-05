# UI 実装・レビュー指針（Native-first / HIG-first）

PulseCue の UI 実装とレビューにおける**恒久ルールの正本**。新規画面・既存画面の変更・
PR レビューのいずれもこの文書に従う。

原則: **Native-first, HIG-first, custom-when-earned.**

- **操作** — SwiftUI / Apple 標準コントロールを第一選択にする
- **構造** — Apple Human Interface Guidelines を外部基準にする
- **ブランド表現** — PulseCue のもの

外部基準: [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)

---

## 1. HIG 準拠は「純正アプリと同じ見た目にすること」ではない

よくある誤解を先に潰しておく。HIG に従うとは、**操作の意味論**（何がタップできるか、
何が主要な操作か、選択とは何か、無効とは何か）を OS と揃えることであって、
見た目を Apple 純正アプリに寄せることではない。

以下は維持してよいし、維持する:

- deep teal / aqua のカラーパレット
- glass / `pulseCard` のカード言語
- タイポグラフィ、角丸、余白のスケール
- ドメイン固有の可視化（Runner の rep 表示、栄養のマクロバー、フォームガイド 3D など）

**視覚的アイデンティティのために意味論を犠牲にしない。** 逆も同じで、意味論を守るために
アイデンティティを捨てる必要もない。両立できないと感じたときは、たいてい標準コントロールに
`.tint` や `.buttonStyle` を当てれば済む。

---

## 2. 操作系は標準コントロールを第一選択にする

| 目的 | 第一選択 |
|---|---|
| アクション | `Button` |
| 画面遷移 | `NavigationLink` |
| ON/OFF | `Toggle` |
| 選択 | `Picker` / `Menu` |
| テキスト入力 | `TextField` / `SecureField` |
| 進捗 | `ProgressView` / `Gauge` |
| 確認 | `alert` / `confirmationDialog` |
| モーダル | `sheet` / `fullScreenCover` |
| ツールバー操作 | `ToolbarItem` |

**標準コントロールで成立する操作を `HStack` + `onTapGesture` で作り直さない。**

`onTapGesture` で作った行は、見た目が同じでも次のものを失う: VoiceOver のボタン特性、
Dynamic Type に追随する最小ヒット領域、押下フィードバック、`disabled` の伝播、
フォーカス、キーボード操作、スイッチコントロール。これらを手で書き直すことは可能だが、
そのコストを払う理由は「見た目を自由にしたい」では足りない。

---

## 3. カスタム View の位置づけ

**カスタム View は禁止しない。** PulseCue の画面の大半は、ドメイン固有のカードと
セクションの組み合わせでできており、それは正しい姿である。

**推奨される用途**（コンポジションと表現）:

- ドメイン固有のカード — `TodayTrainingCard`, `NutritionDailySummaryCard`
- セクション — `NutritionMealsSection`, `TrainingMoreSection`, `HomeMetricsGrid`
- 状態の可視化 — `RunnerStatusChips`, `ProgressBar`
- 再利用される表現プリミティブ — `FrostedCardSurface`, `PulseGlassPlate`

**原則避ける用途**（標準コントロールの再実装）:

- `Button` の代替となるカスタムボタン
- カスタム `Toggle` / `Picker` / ナビゲーションコントロール
- 押下状態の手書き実装
- ジェスチャーだけで操作可能な行

判断基準はひとつ: **それはドメインのコンポジションか、コントロールの再実装か。**
前者なら書いてよい。後者なら §7 の説明責任を負う。

---

## 4. Button

第一選択は system style:

```swift
.buttonStyle(.automatic)   // 既定
.buttonStyle(.bordered)
.buttonStyle(.borderedProminent)
.buttonStyle(.plain)
```

必要に応じて `.tint(_:)` / `.controlSize(_:)` / `.buttonBorderShape(_:)` で調整する。
PulseCue のアクセントカラーは `.tint` で当たる。

カスタム `ButtonStyle` は、**system API では製品要件を満たせない明確な理由がある場合のみ**。
「見た目を自由にしたい」だけでは作らない。

`.buttonStyle(.plain)` + 自前の背景は、カード全体をタップ領域にする行などで妥当な選択で、
これは再実装ではない（`Button` の意味論はそのまま残るため）。

---

## 5. ナビゲーションと presentation の所有権

`NavigationStack` / `NavigationLink` / `toolbar` を第一選択にする。

避けるもの:

- `onTapGesture` だけで行う画面遷移
- 同一 destination への primary route の重複（正規の入口は原則ひとつ）
- 不要な `NavigationStack` のネスト
- presentation の所有権を子へ移すこと

**presentation の所有権は root に置く。** 例として Runner の `fullScreenCover` は
`ContentView` が所有しており、Home からでも Training からでも同じライフサイクルになる。
子が自前で presentation state を持つと、同じ画面が二重に開いたり、セッションが
二重に作られたりする。

---

## 6. state の所有権

| 層 | 持つもの |
|---|---|
| View | 表示とコンポジション |
| ViewModel / domain | 業務上の真実（セッション、集計、永続状態） |
| root | 適切な範囲の presentation ownership |

**表示用のカスタム View が domain truth を `@State` として複製しない。**
値とアクションクロージャを親から受け取る形にする。

```swift
// 良い: 受け取って描画し、タップを返す
struct TodayTrainingCard: View {
    let summary: HomeTrainingSummary
    let onPrimaryAction: () -> Void
}
```

同じ問いに二か所が答えられる状態を作らない。片方が古くなったとき、どちらが正しいかを
判定する方法がなくなる。

---

## 7. カスタムコントロールを新設する場合の説明責任

独自コントロールを作るなら、レビューで少なくとも次を説明できること:

1. 標準 SwiftUI コントロールでは製品要件を満たせない理由
2. HIG の interaction semantics をどう維持するか
3. VoiceOver（label / hint / traits）
4. Dynamic Type（AX XXXL まで）
5. disabled / selected / pressed / focus の各状態
6. ヒット領域 44pt 以上
7. 実際の再利用価値

説明が弱ければ標準コントロールへ戻す。これは却下のための関門ではなく、
**後から気づくと高くつくものを先に洗い出すためのリスト**である。

---

## 8. アクセシビリティの最低基準

- インタラクティブ要素のヒット領域 44pt 以上
- VoiceOver の label（必要なら hint）と traits
- disabled / selected の状態が読み上げに反映される
- Dynamic Type、AX XXXL で破綻しない
- コントラスト
- 意味に合ったコントロールを使う

**標準コントロールが無償で提供しているアクセシビリティを、カスタム実装で失わない。**
これがカスタムコントロールを避ける最大の実務的理由である。

視覚的優先度を下げることと、タップ領域を小さくすることは**別**。
`.bordered` に落とすのはよいが、44pt を割ってはいけない。

---

## 9. 画面内の階層

**画面上の primary action は原則ひとつ。**

secondary / tertiary のアクションを同じ prominence で並べない。system の階層を使う:

| 役割 | style |
|---|---|
| primary | `.borderedProminent` |
| secondary | `.bordered` |
| tertiary | `.plain` |

同じ判断を一画面で二度提示しないこと。「作成」ボタンが二つある画面は、
ユーザーにどちらが正しいかを考えさせている。

---

## 10. UI PR レビューのチェックリスト

- [ ] 標準コントロールで実現できないか
- [ ] `onTapGesture` を `Button` / `NavigationLink` に置き換えられないか
- [ ] カスタム View はドメインのコンポジションか、コントロールの再実装か
- [ ] primary / secondary の階層は明確か（primary はひとつか）
- [ ] ヒット領域は 44pt 以上か
- [ ] VoiceOver の label / hint / traits は正しいか
- [ ] AX XXXL で破綻しないか
- [ ] standard style で十分ではないか
- [ ] 視覚的アイデンティティのために意味論を犠牲にしていないか
- [ ] navigation / state の所有権が二重化していないか

---

## 11. 既存 UI の扱い

**「native 化」を理由に既存 UI を一括で書き換えない。** 動いている画面の一括置換は、
視覚的な差分と挙動の差分が混ざり、レビューできない PR になる。

順序:

1. **review-only の監査** — 実装は変えず、分類だけ行う
2. **KEEP / REPLACE / REVIEW に分類**
   - KEEP: 妥当なドメインカスタム View
   - REPLACE: 標準コントロールを不必要に再実装しているもの
   - REVIEW: カスタムである必要性の判断が要るもの
3. **小さな PR に分割して実施**

各 PR で視覚と挙動の保存を明示する（before / after スクリーンショット、
mutation testing、対象範囲外に触れていないことの確認）。

---

## 12. この文書の位置づけ

この文書が UI 実装ルールの**唯一の正本**である。他のファイルは全文を複製せず、
ここへの参照だけを置く。ルールを変えるときはこの文書を変える。
