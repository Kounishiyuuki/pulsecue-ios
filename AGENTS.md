# PulseCue (iOS)

エージェント向けの入口。ルールの本文はここに置かず、正本へのリンクだけを置く。

## UI の実装とレビュー

**`Docs/ui-engineering-guidelines.md` に従うこと。**

原則は Native-first, HIG-first, custom-when-earned — 操作系は SwiftUI 標準コントロール、
構造は Apple HIG、ブランド表現は PulseCue のもの。カスタムコントロールを新設する場合の
説明責任と、UI PR のレビューチェックリストも同じ文書にある。

## その他の正本

| 目的 | 文書 |
|---|---|
| ビルドと実行 | `README.md` |
| テストの走らせ方 | `TESTING.md` |
| 手動 QA | `Docs/manual-qa-checklist.md` |
| リリース手順 | `Docs/release-process.md` |
| 設計・運用メモ全般 | `Docs/` |
| Cloudflare Workers（server/） | `server/AGENTS.md` |
