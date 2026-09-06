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
前者なら書いてよい。後者なら [§7 の説明責任](#7-カスタムコントロールを新設する場合の説明責任)を負う。

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
- 同じ presentation を複数の View が別々に所有すること
- **必要のない所有権の hoisting**

### presentation state は誰が持つか

**それを必要とする、最小かつ安定した owner が持つ。**

多くの場合それは feature 自身である。sheet や alert を root へ持ち上げるのは
既定の作法ではなく、理由が要る操作である。

**feature-local な presentation は feature が持ってよい**（推奨される形）:

| 例 | owner |
|---|---|
| ログインシート | [`AccountSettingsSection`](../Pulse%20Cue/Views/Settings/AccountSettingsSection.swift) |
| オンボーディング再表示 / 通知アラート | [`AppPreferencesSection`](../Pulse%20Cue/Views/Settings/AppPreferencesSection.swift) |
| 食事入力・スキャナ各シート | [`NutritionView`](../Pulse%20Cue/Views/NutritionView.swift) |

これらを root へ hoist することは**推奨しない**。ログインシートの開閉を
`ContentView` が知る理由はなく、持ち上げれば無関係な階層に状態が増えるだけである。

### ancestor / root へ昇格する理由

次のいずれかに当てはまるとき、共通の祖先（多くは root）へ昇格する:

- 複数の feature / entry point から起動される
- presentation の lifecycle を feature をまたいで維持する必要がある
- 単一のグローバルな presentation truth が必要
- dismissal / resume / session の所有が feature-local では成立しない

**例: Runner。** ホームからもトレーニングからも開始でき、中断して戻ってから再開でき、
セッションの生存期間が画面の生存期間より長い。この3つの要件から共通祖先での所有が
導かれ、実際に [`ContentView`](../Pulse%20Cue/App/ContentView.swift) が
`RunnerPresenter` と `fullScreenCover` を持っている。**Runner がそうだから他も
そうする、ではない** — 要件が同じものだけが同じ結論になる。

---

## 6. state の所有権

| 種類 | owner |
|---|---|
| domain / session の真実 | domain model・ViewModel など適切な所有者 |
| feature の presentation state | その feature の、最小かつ安定した所有者 |
| 一時的なローカル UI state | View のローカル state でよい |
| feature をまたぐ / グローバルな presentation | 正当な理由があるときの共通祖先・root |

**「View は state を持つな」という規則ではない。** 展開状態、フォーカス、入力途中の
テキスト、シートの開閉といった一時的な UI state は、それを使う View が持つのが正しい。

避けるべきなのは所有ではなく**複製**である:

- 同じ問いに二か所が別々に答えられる状態
- 表示用のカスタム View が domain truth を `@State` にコピーすること
- child と root が同じ presentation を同時に管理すること
- presentation の都合だけで domain truth を複製すること

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

### 44pt は標準コントロールを使えば自動で満たされるわけではない

`Button` を使うこと自体は、ヒット領域が 44pt あることを**保証しない**。
`.plain` スタイル、`.controlSize(.small)`、アイコンだけの label、詰まったレイアウトでは
実際のタップ領域が 44pt を下回りうる。標準コントロールが与えるのは意味論
（traits・focus・disabled の伝播）であって、寸法ではない。

したがって:

1. まず native control を選ぶ
2. その上で、**実際のヒット領域**が十分かを確認する
3. 足りなければ、意味論を壊さない形で調整する — `.frame(minHeight:)` /
   `.padding` / `.contentShape(_:)` など

**視覚的な大きさとヒット領域は別物**である。`.borderedProminent` のラベルの見た目が
44pt に見えても、実際に反応する領域がそうとは限らない。逆に、視覚的優先度を下げること
（`.borderedProminent` → `.bordered`）とタップ領域を小さくすることも**別**である。
弱くしてよいが、小さくしてはいけない。

### `contentShape` は anti-pattern ではない

`Button` や `NavigationLink` の**内部**で、行やカード全体を確実にタップ領域にするために
`.contentShape(Rectangle())` を使うのは正しい用法である。`Button` の意味論はそのまま
残るため、これは再実装ではない。

避けるべきなのは組み合わせのほうである:

```swift
// 良い: semantic control の中でタップ領域を正す
NavigationLink { ... } label: {
    HStack { ... }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
}

// 避ける: contentShape + onTapGesture で Button を作り直す
HStack { ... }
    .contentShape(Rectangle())
    .onTapGesture { ... }
```

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
- [ ] **実際の**ヒット領域は 44pt 以上か（標準コントロールでも自動では満たされない）
- [ ] VoiceOver の label / hint / traits は正しいか
- [ ] AX XXXL で破綻しないか
- [ ] standard style で十分ではないか
- [ ] 視覚的アイデンティティのために意味論を犠牲にしていないか
- [ ] presentation state の owner は**最小かつ安定**か（「root か」ではない）
- [ ] 同じ truth を複数の owner が持っていないか
- [ ] 複数 entry point があるのに共通 owner がないままになっていないか
- [ ] feature-local な state を理由なく hoist していないか

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
