# UI インベントリ（デザイン監査 / Stitch 入力用）

PulseCue の本番画面を DEBUG 限定ルートで決定的に撮影し、デザインレビュー/Stitch への入力とするための台帳。**本番UIは再設計しない**。撮影は `Scripts/capture-ui-inventory.sh`、コンタクトシートは `Scripts/build-ui-inventory-contact-sheet.py`。生成画像は `build/ui-inventory/`（`.gitignore` 済み・**commitしない**）。

- 作成日: 2026-07-30 / 対象: `main`（PR #143 反映済み）
- 撮影 sim: iPhone 17 Pro / iOS 26.5 / Portrait / @3x / light / 標準 Dynamic Type / クリーンステータスバー
- 本書は**分割実装**の一部。**Slice 1（本セッション）= 既存ルートで撮れる 16 画面**。Runner追加状態/My Gym追加/Planner追加/Library追加/dark・narrow・全体コンタクトシートは Slice 2–5。

判定: PASS=直接目視で問題なし / 注記=真実だが監査観点あり。

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
- **Planner**: 部位選択(✅) / 単発候補・preview(✅ preview-single) / 週次条件(✅) / 週次候補(✅) / 保存済・invalidation=**未ルート(Slice4)**。
- **Runner**: ACTIVE 1set(✅) / REST(✅) / later set・paused・completion・session-finished・resume=**未ルート(Slice2)**。
- **History**: populated(✅) / detail(✅) / empty・deleted-exercise fallback・long-session=**未ルート(Slice後続)**。
- **My Gym**: active(✅) / machine-selection(✅) / no-gym・multiple・filtered・selected-only・custom add/edit/delete確認・many selected=**未ルート(Slice3)**。
- **Exercise Library**: list(✅) / 検索結果・no result・部位フィルタ・detail・text guide・unsupported 3D=**未ルート(Slice4)**。
- **Form Guide**: 3D成功/側面(✅) / instructions expanded(✅) / 正面・斜め・3D不可fallback・Reduce Motion=**未ルート(Slice後続)**。main現状のみ・PR#140非使用。
- **Settings**: Settings root/認証導線/外観/オンボ再生/ローカルデータ文言=**未ルート（QAルート無し）**。Slice後続で検討。
- **System states**: カメラ/位置の権限説明=**OS権限ダイアログで非決定的（撮影対象外）** / network unavailable=**現状専用UIの有無を要確認** / loading=ユーザー可視の恒常的ローディングは基本無し。

## 撮影・コンタクトシート手順

```
./Scripts/capture-ui-inventory.sh --device <UDID> --variant light --force
python3 Scripts/build-ui-inventory-contact-sheet.py --output build/ui-inventory
# build/ui-inventory/index.html（全体）＋ 各グループ/_contact.html
```

- `--variant light|dark|all`、`--group <NN>`、`--force`（未指定は非上書き）。部分失敗は nonzero、EXIT trap でステータスバー/pref domain 掃除。
- 生成 PNG / HTML は `build/ui-inventory/`（`.gitignore`）。**commitしない**。
- Apple 必要デバイスセット/寸法は提出時に公式で**手動確認**。

## 直接目視の記録（Slice 1）

- 本セッションで直接目視: onboarding / login / planner(target-body-part) / preview-single / weekly-before-generation / history-populated / machine-selection / exercise-library / form-guide-instructions-expanded（9枚・本ターン）＋ home / weekly-candidate / runner-active / runner-rest / history-detail / mygym-active / form-guide（7枚・本セッション先行ターン、同一ルート/fixture/build）。
- **16枚すべて直接目視済み。未確認画像を PASS 扱いしていない。**
