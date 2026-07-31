# UI インベントリ（デザイン監査 / Stitch 入力用）

PulseCue の本番画面を DEBUG 限定ルートで決定的に撮影し、デザインレビュー/Stitch への入力とするための台帳。**本番UIは再設計しない**。撮影は `Scripts/capture-ui-inventory.sh`、コンタクトシートは `Scripts/build-ui-inventory-contact-sheet.py`。生成画像は `build/ui-inventory/`（`.gitignore` 済み・**commitしない**）。

- 作成日: 2026-07-30 / 対象: `main`（PR #143 反映済み）/ 完成: Slice 5
- 撮影 sim（canonical・dark）: iPhone 17 Pro / iOS 26.5 / Portrait / @3x / 標準 Dynamic Type / クリーンステータスバー
- 撮影 sim（narrow）: iPhone SE (3rd gen) / iOS 18.3 / @2x / 375pt幅（deployment target iOS 17.0 と互換）
- **最終インベントリ = 35枚**（canonical 25 + dark 5 + narrow 5）/ 全数直接目視済み（Slice 5 のクリーン再撮影で再確認）。
- 本書は**分割実装（Slice 1–5）**の完成台帳。Slice 1=撮影基盤+16画面 / Slice 2=Runner / Slice 3=My Gym・Machine / Slice 4=Planner・Library / **Slice 5=light/dark/narrow variant・最終監査・コンタクトシート**。

判定: PASS=直接目視で問題なし / 注記=真実だが監査観点あり。

> **外観アーキテクチャ（Slice 5 監査）**: アプリに**アプリ全体の外観設定・永続化はなく、全画面がシステム外観に追従**する。例外は **Runner のみ `.preferredColorScheme(.dark)` を強制**（`RunnerView.swift:73`）。したがって dark variant は非Runner画面でのみ意味があり、Runner の dark variant は light run と同一になるため除外した。
> **narrow の OS caveat**: narrow は iPhone SE (iOS 18.3) で撮影。iOS 26 の Liquid Glass は効かず背景/サーフェスがフラットに見える。narrow variant は**幅レイアウト監査専用**（CTA到達性・truncation・コントロール収まり）であり、外観の視覚参照ではない。

---

## Slice 1 撮影ルート（16画面・全数直接目視済み）

| route ID | 画面 | 状態 | 主目的 | fixture | light/dark | 幅 | 本番可視 | 外部依存 | ファイル | 既知の視覚懸念 |
|---|---|---|---|---|---|---|---|---|---|---|
| onboarding | Onboarding | 初回・ゲスト導線 | ログイン不要で開始 | (静的) | light | 標準 | ✅ | なし | 01-onboarding/onboarding.png | 中央〜下部の余白多（sparse） |
| login | LoginView | 続ける方法選択 | 任意ログイン | AuthSessionStore(空) | light | 標準 | ✅※ | Apple/Google SDK | 02-auth/login.png | **DEBUG表示**でGoogle「設定準備中」可視（Releaseは非表示=PR#142）。下部余白多 |
| home | Home/Today | 0/4・ジム準備済 | 今日を始める | Pulse Fitness 渋谷(11マシン) | light | 標準 | ✅ | なし | 03-home/home.png | 「ジムからメニュー作成」に✨（装飾・AI非主張） |
| planner | 部位選択 | 胸選択済 | 鍛える部位選択 | Pulse Fitness 渋谷 | light | 標準 | ✅ | なし | 05-planner/target-body-part.png | 下部余白 |
| preview-single | 単発プランPreview | 生成済(目安あり) | 確認して保存 | 渋谷+chest | light | 標準 | ✅ | なし | 05-planner/preview-single.png | 良好（3×10×90等の実値） |
| preview-weekly-before-generation | 週次条件 | 生成前 | 生成条件を選ぶ | (入力のみ) | light | 標準 | ✅ | なし | 05-planner/weekly-before-generation.png | 良好 |
| preview-weekly | 週次候補 | 生成済 | 候補確認・保存 | weeklyCandidate | light | 標準 | ✅ | なし | 05-planner/weekly-candidate.png | **「目安なし」×4**（カタログ未登録種目の真実表示・empty-state品質） |
| runner-active | Runner ACTIVE | exercise 1set目 | 種目/セット記録 | 上半身プッシュ | light | 標準 | ✅ | なし | 06-runner/runner-active.png | 良好 |
| runner-rest | Runner REST | 休憩 | 休憩管理 | 上半身プッシュ | light | 標準 | ✅ | なし | 06-runner/runner-rest.png | **可視秒はライブ**（相は決定的・秒は非決定的） |
| history-populated | History一覧 | 3セッション | 履歴確認 | fixture 3 sessions | light | 標準 | ✅ | なし | 07-history/history-populated.png | 下部余白多 |
| history-detail | Session詳細 | 3種目全解決 | 実施記録確認 | featuredSession | light | 標準 | ✅ | なし | 07-history/history-detail.png | 良好 |
| mygym-active | My Gym | アクティブジム | ジム/マシン管理 | Pulse Fitness 渋谷 | light | 標準 | ✅ | なし | 08-my-gym/mygym-active.png | **`example.com`** 表示（fixture officialUrl・要fixture修正 Slice3）・✨装飾 |
| machine-selection | マシン選択 | 一部選択(11台) | 使えるマシン更新 | 渋谷+11 | light | 標準 | ✅ | なし | 08-my-gym/machine-selection.png | 良好 |
| exercise-library | Exercise Library | 一覧 | フォーム確認 | ExerciseLibrary | light | 標準 | ✅ | なし | 09-library/exercise-library.png | 部位アイコンが汎用的（component一貫性） |
| form-guide | Form Guide 3D | 折り畳み | 動きを3D+テキスト | machine_chest_press | light | 標準 | ✅ | なし | 10-form-guide/form-guide.png | **main現状capsule**（PR#140非依存） |
| form-guide-instructions-expanded | Form Guide 3D | テキスト展開 | 手順テキスト | 同上 | light | 標準 | ✅ | なし | 10-form-guide/form-guide-instructions-expanded.png | 同上 |

※ login は Release では Google コントロール非表示（PR#142）。本 inventory は DEBUG 撮影のため Google 不可視状態が写る。

## 検出した UI 懸念（カテゴリ別・本PRでは修正しない）

- **empty-state品質**: preview-weekly の「目安なし」×4（カタログ未登録種目の真実表示だが未完成に見えやすい）。→ 既定を持つマシン中心の fixture request で改善余地（Slice 4 任意）。
- **spacing/whitespace**: onboarding / login / planner / history-populated で中央〜下部の余白が大きく sparse に見える箇所。calm 意図か過剰かは要デザイン判断。
- **component一貫性**: exercise-library の部位アイコンが複数種目で汎用（歩行アイコン等）で識別性が弱い。
- **fixtureデータ品質（本番UIではなくfixture）**: My Gym の `example.com`（fixture officialUrl）は inventory 要件「no example.com」に反する。**Slice 3 で fixture officialUrl を実在感ある非example値へ**（本番挙動不変）。
- **CTA competition**: home で青CTA(ワークアウトを開始)とジムカードの青ボタンが2つ（既知・PR#134レビューで許容済み）。
- **light/dark identity**: Runner系は atmospheric 背景が深い青（light撮影でも濃色）。light/dark 一貫性は Slice 5 で dark 撮影後に評価。

## 完全な画面監査（全フロー・未ルート状態を含む・invent しない）

以下は「存在する画面/状態」の台帳。**Slice 1 で未撮影のものは後続 Slice**。存在しない状態は「該当なし」と明記し、将来API/アカウント/PR#140挙動を実装済みとして扱わない。

- **Onboarding/Auth**: onboarding(✅Slice1) / login(✅) / Apple可(login内) / ゲスト継続(login内) / 認証エラー・キャンセル提示=**明示的な専用画面は無し**（キャンセルで状態不変・ゲスト継続）。
- **Home/Today**: 0/4準備済(✅) / 部分入力・完了入力=**未ルート(Slice後続・DayLog seed要)** / ジム未設定=**未ルート**。
- **Workout(ルート)**: WorkoutView ルート=**未実装（既存QAルートに無し）**。Slice後続で検討。
- **Planner**: 部位選択(✅) / 単発候補・preview(✅ preview-single) / 週次条件(✅) / 週次候補(✅) / 生成不可(✅ planner-unavailable-target・Slice4) / 保存済・invalidation=**omit（Slice4監査: 遷移のみ/視覚同一）**。
- **Runner**: ACTIVE 1set(✅) / REST(✅) / later set・paused・completion・session-finished・resume=**未ルート(Slice2)**。
- **History**: populated(✅) / detail(✅) / empty・deleted-exercise fallback・long-session=**未ルート(Slice後続)**。
- **My Gym**: active(✅) / machine-selection(✅) / no-gym・multiple・filtered・selected-only・custom add/edit/delete確認・many selected=**未ルート(Slice3)**。
- **Exercise Library**: list(✅) / 検索結果(✅ search-results・Slice4) / no result(✅ search-no-results・Slice4) / 部位フィルタ=**omit（独立UI無し）** / detail・text guide=**omit（form-guide と冗長）** / unsupported 3D=**omit（存在しない）**。
- **Form Guide**: 3D成功/側面(✅) / instructions expanded(✅) / 正面・斜め・3D不可fallback・Reduce Motion=**未ルート(Slice後続)**。main現状のみ・PR#140非使用。
- **Settings**: Settings root/認証導線/外観/オンボ再生/ローカルデータ文言=**未ルート（QAルート無し）**。Slice後続で検討。
- **System states**: カメラ/位置の権限説明=**OS権限ダイアログで非決定的（撮影対象外）** / network unavailable=**現状専用UIの有無を要確認** / loading=ユーザー可視の恒常的ローディングは基本無し。

## Slice 2: Runner 状態監査（本番の実挙動に基づく）

依頼された5状態をリポジトリで監査。**存在しない/独立画面でないものは捏造せず omit**。

| 依頼状態 | 本番に存在? | 判定 | 理由 |
|---|---|---|---|
| ACTIVE later set | ✅ | **新ルート追加** | exercise相を後半セットへ進めて撮影可（静的・決定的） |
| paused | ❌ | **omit** | `RunnerAction` は complete/skip/extend/back のみ。**一時停止アクション/UIは存在しない** |
| completion（完了サマリ） | ❌ | **omit** | 完了で `phase=.done`→`isRunning=false`→cover 自動 dismiss。**独立した完了サマリ画面は無い**。偽メトリクスは作らない |
| session-finished 確認 | 部分 | **omit（独立撮影不可）** | 唯一の終了系UIは `.alert("セッションを終了しますか？…中断として保存")`（RunnerView内 @State・host注入不可）。iOS標準alertでデザイン価値低・本番View改変を避け omit |
| resume existing session | ❌（非独立） | **omit** | `RunnerPresenter` が同じ active Runner を再提示するだけで、**runner-active と視覚的に同一**。独立画面なし |

→ **Slice 2 の新ルートは `runner-active-later-set` の1件のみ**（他4は上記理由で omit）。

### Slice 2 新ルート

| route ID | 画面 | 状態 | 主目的 | 決定性 | fixture | 本番可視 | ファイル | 直接目視 | 視覚懸念 |
|---|---|---|---|---|---|---|---|---|---|
| runner-active-later-set | Runner ACTIVE | 2セット目(2/3) | 進行中の記録 | **完全決定的**（exercise相・timer非稼働） | 上半身プッシュ（start+complete×2） | ✅ | 06-runner/runner-active-later-set.png | **YES（本セッション）** | 良好。runner-active(1/3)と明確に区別 |

### Runner 決定性分類（全Runnerルート）
- `runner-active` = **完全決定的**（exercise相・静的）
- `runner-active-later-set` = **完全決定的**（exercise相・2/3・静的）
- `runner-rest` = **相は決定的・可視秒はライブ**（本番rest timer・bounded timing-dependent）

### Runner 固有 UI 懸念（本PRでは未修正）
- Runner 系は atmospheric 背景が深い青（light撮影でも濃色）。light/dark 一貫性は Slice 5 の dark 撮影で評価。
- 主CTA「完了」がボトム action bar 中央で明確（primary CTA clarity 良好）。「セッション終了」は赤字tertiaryで destructive として適切に控えめ。
- 下部（NEXT UP と action bar の間）に余白あり（calm 意図）。

### 直接目視の記録（Slice 2）
- 本セッションで直接目視: `runner-active-later-set`（1枚・新規）。既存 `runner-active` / `runner-rest` は再撮影・変更なし（Slice 1 で目視済み・本Sliceで挙動不変）。
- **新規生成画像を全数直接目視。未確認を PASS 扱いしていない。**

## Slice 3: My Gym / Machine / Custom Machine 状態監査

依頼10状態をリポジトリ監査。既存Viewを isolated in-memory container で再現（本番store非書込み）。捏造せず、不可/冗長は omit。

| 依頼状態 | 判定 | 理由 |
|---|---|---|
| no gym | **新ルート** `mygym-empty` | MyGymHomeView の空状態（`gyms.isEmpty`）を空containerで再現 |
| active gym | **既存 regenerate** `mygym-active` | fixture officialUrl を nil 化し example.com を除去して再撮影 |
| multiple gyms | **新ルート** `mygym-multiple` | 渋谷(active)＋Central Training Lab(inactive・6台) |
| body-part filtered | **omit** | フィルタは viewModel の @State（chipタップ）で、注入不可。production-state injection なしに到達不可 |
| selected-only | **omit** | 同上（`showSelectedOnly` @State） |
| no machines selected | **新ルート** `machine-selection-none-selected` | 0選択のジムで 0/8・選択済み0台 |
| many selected | **omit（冗長）** | 既存 `machine-selection`（11台選択）が many を既にカバー |
| custom add | **新ルート** `custom-machine-add` | `CustomMachineFormView(gym:)` 空フォーム |
| custom edit | **新ルート** `custom-machine-edit` | `CustomMachineFormView(gym:, editing:)` populate |
| delete confirmation | **omit** | GYM/CustomMachine 削除は `pendingDeletion`/`editingCustomMachine` 等の @State 依存の alert/sheet。**not independently capturable without production-state injection**。偽確認画面は作らない |

→ **Slice 3 = 新ルート5 ＋ regenerate 1**（他4は上記理由で omit）。

### Slice 3 ルート

| route ID | 画面 | 状態 | 主目的 | 決定性 | fixture | 永続化隔離 | ファイル | 直接目視 | 懸念 |
|---|---|---|---|---|---|---|---|---|---|
| mygym-active（regen） | My Gym | アクティブ | ジム/マシン管理 | 決定的 | 共有fixture(officialUrl=nil) | in-memory | 08-my-gym/mygym-active.png | **YES** | ✨装飾（既存） |
| mygym-empty | My Gym | ジムなし | ジム登録誘導 | 決定的 | 空container | 独立in-memory | 08-my-gym/mygym-empty.png | **YES** | 下部余白多／「自動生成」はルールベース |
| mygym-multiple | My Gym | 複数ジム | 切替・管理 | 決定的 | 2gym container | 独立in-memory | 08-my-gym/mygym-multiple.png | **YES** | 「同期済み」は既存コピー（cloud非該当） |
| machine-selection-none-selected | マシン選択 | 0選択 | 使えるマシン更新 | 決定的 | 0選択gym | 独立in-memory | 08-my-gym/machine-selection-none-selected.png | **YES** | 良好 |
| custom-machine-add | Custom Machine | 追加(空) | 器具を登録 | 決定的 | gymのみ | 独立in-memory・自動insert無し | 08-my-gym/custom-machine-add.png | **YES** | 良好（追加する は無効まで） |
| custom-machine-edit | Custom Machine | 編集(populate) | 器具を編集 | 決定的 | CustomMachine(ケーブルロー/背中/ケーブル/フォーム確認用) | 独立in-memory | 08-my-gym/custom-machine-edit.png | **YES** | 良好（変更を保存 で edit明確） |

### officialUrl / example.com 修正
- 共有 fixture `Gym.officialUrl` を `"https://example.com/..."` → **`nil`** に修正（**DEBUG fixture のみ**・本番URL描画挙動不変）。My Gym の URL 行が自然に非表示。regenerate した `mygym-active` で **example.com 不在を直接目視確認**。架空の実在風URLは導入せず。

### Slice 3 UI 懸念（本PRでは未修正）
- **empty-state品質**: mygym-empty の下部余白が大きい。
- **copy/component一貫性**: 「メニューを自動生成」「同期済み」等の既存コピーが auto/cloud を弱く示唆（実際はルールベース/ローカル）。将来コピー検討。
- **destructive prominence**: 削除確認は本監査で撮影不可（@State依存）だが、コード上は alert/confirmationDialog で cancel/削除(destructive) の階層あり。

### 直接目視の記録（Slice 3）
- 本セッションで直接目視: mygym-active(regen) / mygym-empty / mygym-multiple / machine-selection-none-selected / custom-machine-add / custom-machine-edit（**6枚全数**）。
- **未確認を PASS 扱いしていない。**

## Slice 4: Planner / Exercise Library 状態監査

依頼13状態をリポジトリ監査。本番View（`WeeklyTrainingPlanCandidateReviewView` / `ExerciseLibraryView`）を DEBUG 限定 init で再現（本番挙動・永続化・生成ルール不変）。捏造せず、冗長/不可/存在しないものは omit。

### Planner

| 依頼状態 | 判定 | 理由 |
|---|---|---|
| saved single-plan | **omit** | 単発保存は保存後に前画面へ**遷移**するだけで、安定した専用「保存済み」画面が無い。偽バッジは作らない |
| saved weekly-plan | **omit（撮影冗長）** | `.saved` は successCard に変わるが、その card は day cards の**後（fold下）**にあり、単一スクショの可視領域は `preview-weekly` と同一。決定的な単一撮影で視覚差が出ないため omit |
| generation invalidated | **omit（視覚同一）** | 入力変更で候補は**クリア**され、通常の入力前画面（`preview-weekly-before-generation`）と視覚的に同一。挙動として記録し重複画像は作らない |
| single-plan input（未撮影） | **omit（冗長）** | 単発入力は既存 `planner`（部位選択）と実質同じ入力階層。新規視覚情報なし |
| generated candidate/preview（未撮影） | **omit（冗長）** | `preview-single` / `preview-weekly` で既にカバー |
| invalid/unavailable generation | **新ルート** `planner-unavailable-target` | ジム未選択時の実 `equipmentNotice`（「使用するジムを My Gym で選択してください。」）を表示。生成不可の本番可視状態で視覚的に明確 |

### Exercise Library

| 依頼状態 | 判定 | 理由 |
|---|---|---|
| search result | **新ルート** `exercise-library-search-results` | 実カタログ検索「プレス」で3件（チェスト/レッグ/ショルダープレス）。`searchText` を DEBUG init で初期化（本番の空既定・編集可挙動は不変） |
| no search result | **新ルート** `exercise-library-no-results` | 「スイム」で実 empty-state（「一致する種目がありません」）。捏造クエリ・テスト語なし |
| body-part filter | **omit** | ライブラリに独立した部位フィルタ UI は無し（検索のみ）。ルート名だけの重複は作らない |
| exercise detail | **omit（冗長）** | detail は `.sheet` → `ExerciseGuideView`（＝Form Guide）。既存 `form-guide` ルートと同一 |
| text guide | **omit（冗長）** | テキスト手順は既存 `form-guide-instructions-expanded` が同一情報をカバー |
| unsupported 3D / fallback | **omit（存在しない）** | ライブラリは `FormGuideLibrary.hasGuide` の10種目のみ表示し、その10種目すべてに `ExerciseMotionLibrary` の3Dプロファイルが存在。「ガイドあり・3Dなし」状態は current-main に存在しない（`formGuideSupportMappingIsUnchanged` テストで固定） |
| supported Form Guide entry | **omit（冗長）** | 既存 `form-guide` が supported エントリを既にカバー |

→ **Slice 4 = 新ルート3件**（`planner-unavailable-target` / `exercise-library-search-results` / `exercise-library-no-results`）。他10状態は上記理由で omit。依頼リストは監査対象であり、1ラベル=1ルートを強制しない方針に従い、視覚的に真に distinct なもののみ採用。

### Slice 4 新ルート

| route ID | 画面 | 状態 | 主目的 | 決定性 | fixture/入力 | 永続化隔離 | ファイル | 直接目視 | 懸念 |
|---|---|---|---|---|---|---|---|---|---|
| planner-unavailable-target | 週次候補レビュー | 生成不可(ジム未選択) | 生成前提の欠如提示 | 決定的（静的 notice） | `debugEquipmentNotice`（実 `needsActiveGymMessage`） | 永続化なし（候補・保存なし） | 05-planner/unavailable-target.png | **YES（本セッション）** | 良好。下部に notice、生成ルール不変 |
| exercise-library-search-results | Exercise Library | 検索一致(「プレス」3件) | 種目検索→フォーム確認 | 決定的（固定クエリ・実カタログ・安定順） | `debugInitialSearch: "プレス"` | なし（読み取りのみ） | 09-library/search-results.png | **YES** | キーボード非表示・fake行なし・実フィルタ結果 |
| exercise-library-no-results | Exercise Library | 検索0件(「スイム」) | 空状態提示 | 決定的（固定クエリ） | `debugInitialSearch: "スイム"` | なし | 09-library/search-no-results.png | **YES** | 実 empty copy・stale行なし・テスト語なし |

### Slice 4 DEBUG init（本番挙動不変）
- `WeeklyTrainingPlanCandidateReviewView(debugEquipmentNotice:)` — `equipmentNotice` の初期値のみ設定。候補生成・保存・永続化は行わない。
- `ExerciseLibraryView(debugInitialSearch:)` — `searchText` の初期値のみ設定。本番の空既定・編集可・検索ロジックは不変。
- いずれも `#if DEBUG`・本番ナビゲーション/persistence/生成ルールに変更なし。

### Form Guide 制約メモ（PR #140 非依存）
- ライブラリの表示対象＝ガイド10種目＝3Dモーションプロファイル10種目（`machine_*` / `lat_pulldown` / `leg_*` / `cable_triceps_pushdown`）。**ガイドあり・3Dなしの unsupported 状態は current-main に存在しない**。PR #140 の rigged model は未マージのため「将来3D対応」を実装済みとして扱わない。

### 直接目視の記録（Slice 4）
- 本セッションで直接目視: `planner-unavailable-target` / `exercise-library-search-results` / `exercise-library-no-results`（**3枚全数**）。
- 撮影後の監査で `planner-weekly-saved` は successCard が fold下で単一スクショに写らず `preview-weekly` と視覚同一と判明したため、**ルートごと削除**（enum/switch/capture script/テスト/DEBUG init param・生成 PNG も削除）。
- **未確認を PASS 扱いしていない。**

## Slice 5: 外観/端末 variant・最終監査

### インベントリサマリ
- **最終合計 35枚** = canonical 25 + dark 5 + narrow 5
- route数 25（enum `GlassUIVisualQARoute` の全ケース。variant は同一routeを別外観/別端末で撮影したもので route増ではない）
- 全35枚を Slice 5 のクリーン再撮影（`build/ui-inventory` 削除→`--variant all`）で生成し、**全数を本セッションで直接目視**（全PASS・失敗0）
- omit した依頼 variant / 状態は各Slice監査表に記録済み（Slice 2–4 参照）
- current-main 制約: Form Guide は簡易capsule 3D（PR #140 未マージ）/ narrow は iOS 18.3（Liquid Glass 非適用）/ Runner は常時dark

### 選定した variant と理由
dark（5・primary 17 Pro・非Runner中心。Glass/PulseUI/MyGymStyle が colorScheme 依存で実際に差が出る画面）:

| variant | route | 理由 |
|---|---|---|
| home-dark | home | 低密度ダッシュボード・Glassカードの dark 表現 |
| weekly-candidate-dark | preview-weekly | 高密度プランニング・多数カードの dark |
| mygym-multiple-dark | mygym-multiple | 管理リストの dark・サーフェス分離 |
| custom-machine-edit-dark | custom-machine-edit | フォーム（PulseUI フィールドプレートが dark で変化） |
| exercise-library-dark | exercise-library | リスト行の dark 可読性 |

narrow（5・iPhone SE 375pt・幅レイアウトが最も影響する画面）:

| variant | route | 理由 |
|---|---|---|
| onboarding-narrow | onboarding | hero + 下部CTA到達性 |
| home-narrow | home | ダッシュボードカードの reflow |
| weekly-candidate-narrow | preview-weekly | 密なカードの truncation/scroll |
| runner-active-narrow | runner-active | 下部 action bar（戻る/+10s/完了/スキップ）の収まり |
| machine-selection-narrow | machine-selection | フィルタchip横スクロール・カウント・保存バーの収まり |

**除外した variant**: Runner の dark（常時darkのため冗長）/ Form Guide の narrow・dark（3Dシーンの照明は固定で幅/外観差の情報価値が低い）/ 全routeの網羅的 light/dark/narrow（視覚差の無い画面を増やさない方針）。

### 最終画像インベントリ（35枚）
外部サービス依存: 全画像 **なし**（ネット/AI/実API不使用）。fixture は全て isolated in-memory。決定性: 特記なき限り**完全決定的**。

| # | filename | route | 画面/状態 | 外観 | 端末 | fixture | 目的 | 決定性 | 目視 | 懸念 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 01-onboarding/onboarding.png | onboarding | 初回・ゲスト導線 | Light | 17 Pro | 静的 | ログイン不要で開始 | 完全 | PASS | 下部余白多 |
| 2 | 01-onboarding/onboarding-narrow.png | onboarding | 同上 | Light | SE | 静的 | 幅監査 | 完全 | PASS | iOS18でフラット(caveat) |
| 3 | 02-auth/login.png | login | 続ける方法選択 | Light | 17 Pro | AuthSessionStore(空) | 任意ログイン | 完全 | PASS | DEBUGでGoogle「準備中」可視(Release非表示) |
| 4 | 03-home/home.png | home | 0/4・ジム準備済 | Light | 17 Pro | 渋谷11台 | 今日を始める | 完全 | PASS | ✨装飾(AI非主張) |
| 5 | 03-home/home-dark.png | home | 同上 | Dark | 17 Pro | 渋谷11台 | dark表現 | 完全 | PASS | 良好 |
| 6 | 03-home/home-narrow.png | home | 同上 | Light | SE | 渋谷11台 | 幅監査 | 完全 | PASS | 良好 |
| 7 | 05-planner/target-body-part.png | planner | 胸選択済 | Light | 17 Pro | 渋谷 | 部位選択 | 完全 | PASS | 下部余白 |
| 8 | 05-planner/preview-single.png | preview-single | 単発生成(目安あり) | Light | 17 Pro | 渋谷+chest | 確認して保存 | 完全 | PASS | 良好(実値) |
| 9 | 05-planner/weekly-before-generation.png | preview-weekly-before-generation | 週次入力(生成前) | Light | 17 Pro | 入力のみ | 生成条件選択 | 完全 | PASS | 良好 |
| 10 | 05-planner/weekly-candidate.png | preview-weekly | 週次候補(生成済) | Light | 17 Pro | weeklyCandidate | 候補確認 | 完全 | PASS | 目安なし×4(empty-state品質) |
| 11 | 05-planner/weekly-candidate-dark.png | preview-weekly | 同上 | Dark | 17 Pro | weeklyCandidate | dark表現 | 完全 | PASS | 目安なしchipがdarkで低コントラスト |
| 12 | 05-planner/weekly-candidate-narrow.png | preview-weekly | 同上 | Light | SE | weeklyCandidate | 幅監査 | 完全 | PASS | 良好(密でも正常wrap) |
| 13 | 05-planner/unavailable-target.png | planner-unavailable-target | 生成不可(ジム未選択) | Light | 17 Pro | equipmentNotice | 前提欠如提示 | 完全 | PASS | 良好 |
| 14 | 06-runner/runner-active.png | runner-active | exercise 1/3 | Dark(強制) | 17 Pro | 上半身プッシュ | 記録 | 完全 | PASS | 良好 |
| 15 | 06-runner/runner-active-later-set.png | runner-active-later-set | exercise 2/3 | Dark(強制) | 17 Pro | 上半身プッシュ | 進行中記録 | 完全 | PASS | 良好(1/3と区別) |
| 16 | 06-runner/runner-active-narrow.png | runner-active | exercise 1/3 | Dark(強制) | SE | 上半身プッシュ | 幅監査 | 完全 | PASS | action bar収まりOK |
| 17 | 06-runner/runner-rest.png | runner-rest | 休憩 | Dark(強制) | 17 Pro | 上半身プッシュ | 休憩管理 | 相決定的・秒ライブ | PASS | 可視秒はライブ |
| 18 | 07-history/history-populated.png | history-populated | 3セッション | Light | 17 Pro | 3 sessions | 履歴確認 | 完全 | PASS | 下部余白多 |
| 19 | 07-history/history-detail.png | history-detail | 3種目全解決 | Light | 17 Pro | featuredSession | 実施記録 | 完全 | PASS | 良好 |
| 20 | 08-my-gym/mygym-active.png | mygym-active | アクティブ | Light | 17 Pro | 渋谷(url=nil) | ジム管理 | 完全 | PASS | ✨装飾 |
| 21 | 08-my-gym/mygym-empty.png | mygym-empty | ジムなし | Light | 17 Pro | 空container | 登録誘導 | 完全 | PASS | 下部余白多 |
| 22 | 08-my-gym/mygym-multiple.png | mygym-multiple | 複数ジム | Light | 17 Pro | 2gym | 切替管理 | 完全 | PASS | 「同期済み」既存コピー |
| 23 | 08-my-gym/mygym-multiple-dark.png | mygym-multiple | 同上 | Dark | 17 Pro | 2gym | dark表現 | 完全 | PASS | 良好 |
| 24 | 08-my-gym/machine-selection.png | machine-selection | 一部選択(11台) | Light | 17 Pro | 渋谷+11 | マシン更新 | 完全 | PASS | 良好 |
| 25 | 08-my-gym/machine-selection-narrow.png | machine-selection | 同上 | Light | SE | 渋谷+11 | 幅監査 | 完全 | PASS | フィルタchip横スクロール(仕様) |
| 26 | 08-my-gym/machine-selection-none-selected.png | machine-selection-none-selected | 0選択 | Light | 17 Pro | 0選択gym | 空選択状態 | 完全 | PASS | 良好 |
| 27 | 08-my-gym/custom-machine-add.png | custom-machine-add | 追加(空) | Light | 17 Pro | gymのみ | 器具登録 | 完全 | PASS | 追加する無効まで |
| 28 | 08-my-gym/custom-machine-edit.png | custom-machine-edit | 編集(populate) | Light | 17 Pro | CustomMachine | 器具編集 | 完全 | PASS | navタイトルtruncation(既存) |
| 29 | 08-my-gym/custom-machine-edit-dark.png | custom-machine-edit | 同上 | Dark | 17 Pro | CustomMachine | dark表現 | 完全 | PASS | フォームfieldネイティブ |
| 30 | 09-library/exercise-library.png | exercise-library | 一覧 | Light | 17 Pro | ExerciseLibrary | フォーム確認 | 完全 | PASS | 部位アイコン汎用 |
| 31 | 09-library/exercise-library-dark.png | exercise-library | 同上 | Dark | 17 Pro | ExerciseLibrary | dark表現 | 完全 | PASS | 良好 |
| 32 | 09-library/search-results.png | exercise-library-search-results | 検索一致「プレス」3件 | Light | 17 Pro | debugInitialSearch | 検索結果 | 完全 | PASS | キーボードなし・fake行なし |
| 33 | 09-library/search-no-results.png | exercise-library-no-results | 検索0件「スイム」 | Light | 17 Pro | debugInitialSearch | 空状態 | 完全 | PASS | 実empty copy |
| 34 | 10-form-guide/form-guide.png | form-guide | 3D側面(折畳) | Light | 17 Pro | machine_chest_press | 動き確認 | 完全(static0.35) | PASS | **main現状capsule**(視覚品質参照は非推奨) |
| 35 | 10-form-guide/form-guide-instructions-expanded.png | form-guide-instructions-expanded | テキスト展開 | Light | 17 Pro | 同上 | 手順テキスト | 完全 | PASS | 同上 |

### プロダクト全体 UI 監査（発見のみ・本PRでは未修正）
- **情報階層**: 概ね明確（大タイトル→説明→カード→CTA）。Planner候補は生成条件が折り畳まれ候補が主になる遷移が良好。
- **whitespace**: onboarding / login / planner / history-populated / mygym-empty で中央〜下部余白が大きく sparse に見える。calm 意図か過剰かは要デザイン判断。
- **typography**: largeTitle 中心で一貫。長い nav inline タイトル（カスタムマシン編集）は truncation。
- **CTA competition**: home で青CTA（ワークアウト開始）とジムカード青ボタンが併存（既知・許容済み）。
- **excess card usage**: 概ね適切。Planner候補は情報量が多くカードが縦に長い。
- **Glass consistency**: light/dark とも Glass 表現は一貫（PulseUI/MyGymStyle が colorScheme 対応）。ただし narrow は iOS18 で Glass 非適用のためフラット。
- **light/dark identity**: 全画面 dark で製品同一性を維持。Runner は常時dark。
- **navigation clarity**: 明確。閉じる/キャンセル/戻るが一貫。
- **empty-state quality**: mygym-empty は良好だが余白大。**weekly 候補の「目安なし」×4** は真実だが未完成に見えやすい（最大の監査観点。dark で更に低コントラスト）。
- **form density**: Custom Machine フォームは適切な密度。
- **component consistency**: カード/チップ/セグメントは一貫。
- **icon consistency**: **Exercise Library の部位アイコンが汎用**（歩行アイコン等）で識別性が弱い。
- **narrow-layout behavior**: 375pt で CTA到達性・truncation・下部コントロール収まりに致命的問題なし。フィルタchipは横スクロール（仕様）。
- **perceived product maturity**: 全体に整っているが、(1)「目安なし」多発、(2)部位アイコン汎用、(3)一部画面の余白過多、が「未完成感」を与えうる主因。

### Stitch 受け渡し
- **アップロード順**: まずグループ別コンタクトシート（`build/ui-inventory/<NN-group>/_contact.html`）と全体 `index.html` を開き、各カードの外観/端末ラベルで俯瞰 → 下記6枚を最優先アップロード。
- **推奨する最初の6枚（代表）**:
  1. Light 低密度: `03-home/home.png`（ダッシュボード）
  2. Light 高密度: `05-planner/preview-single.png`（生成プラン・実値の情報密度）
  3. Dark インタラクティブ: `06-runner/runner-active.png`（常時dark・操作系）
  4. プランニング: `05-planner/weekly-candidate.png`（週次候補）
  5. 管理: `08-my-gym/machine-selection.png`（マシン選択・チェック/カウント）
  6. 履歴/読み取り: `07-history/history-detail.png`（実施記録）
- **視覚参照にしない画面**: `10-form-guide/*`（**現状は簡易capsule 3D**。PR #140 の rigged model 未マージのため、フォームガイドの3D品質を Stitch のデザイン基準にしない）。narrow 画像（iOS18でGlass非適用のため外観参照に不適・幅監査専用）。
- **現在のプロダクト能力境界**: ローカルのみ（同期/バックアップ未実装・「今後対応予定」）/ プラン生成はルールベース（AI/サーバー/クラウド非該当）/ Google ログインは未設定（Release非表示）/ Form Guide は限定10種目・簡易3D。
- **グループ構成**: `01-onboarding` `02-auth` `03-home` `05-planner` `06-runner` `07-history` `08-my-gym` `09-library` `10-form-guide` の9グループ。各 `_contact.html` に外観/端末ラベル付き。

### 直接目視の記録（Slice 5・最終）
- 本セッションで **35枚全数を直接目視**（canonical 25 + dark 5 + narrow 5）。全PASS・失敗0。前Slice目視に依存せず、クリーン再撮影の実画像で再確認。
- コンタクトシートは HTML（`index.html` + 9グループ `_contact.html`）を生成。img参照35件すべて実在・欠落0・重複0・グループ合計35一致を構造検証。PNG atlas は新規依存（PIL等）が必要なため HTML を採用。
- **未確認画像を PASS 扱いしていない。**

## 撮影・コンタクトシート手順

```
# 最終フルキャプチャ（canonical + dark + narrow）
./Scripts/capture-ui-inventory.sh \
  --device <PRIMARY_UDID> \
  --narrow-device <NARROW_UDID> \
  --variant all --force
python3 Scripts/build-ui-inventory-contact-sheet.py --output build/ui-inventory
# build/ui-inventory/index.html（全体）＋ 各グループ/_contact.html
```

- `--variant light|dark|narrow|all`。`light`=canonical 25（primary/light）、`dark`=選択5（primary/dark）、`narrow`=選択5（narrow端末/light）、`all`=35枚全部。
- `--narrow-device <UDID>` は narrow/all で必須（未指定時は iPhone SE を名前解決）。UUIDは常に完全指定・prefix依存しない。`--group <NN>`、`--force`（未指定は非上書き）。
- 部分失敗は nonzero、EXIT trap で両端末のステータスバー/pref domain/外観を掃除（macOSホスト外観は変更しない）。
- 生成 PNG / HTML は `build/ui-inventory/`（`.gitignore`）。**commitしない**。
- Apple 必要デバイスセット/寸法は提出時に公式で**手動確認**。

## 直接目視の記録（Slice 1）

- 本セッションで直接目視: onboarding / login / planner(target-body-part) / preview-single / weekly-before-generation / history-populated / machine-selection / exercise-library / form-guide-instructions-expanded（9枚・本ターン）＋ home / weekly-candidate / runner-active / runner-rest / history-detail / mygym-active / form-guide（7枚・本セッション先行ターン、同一ルート/fixture/build）。
- **16枚すべて直接目視済み。未確認画像を PASS 扱いしていない。**
