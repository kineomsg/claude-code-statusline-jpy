# コードレビュー結果 (2026-07-14)

対象: statusline.sh / statusline.ps1 / install.sh / uninstall.sh
レビュアー: Claude Code (Fable 5)
**ステータス: 完了。修正・テスト・コミット・pushまで完了済み。**

- 公開リポジトリ `claude-code-statusline-jpy`: commit `98ab319` → `origin/main` push済み
- 実運用デプロイ先 `dotfiles-claude`（`~/.claude/statusline.sh` のリンク先）: commit `4697927` → `origin/master` push済み。この環境の実ステータスラインに反映済み
- bash 版は fake HOME 環境でテスト済み。**statusline.ps1 はこのサーバーに PowerShell が無いため未検証** — Windows 環境での動作確認が必要（唯一の残タスク）

## バグ（修正済み）

1. **複数セッション同時実行で Today 累計が水増し** — `cost_budget.cache` を全セッション共有し「コスト減少=セッション再開」ヒューリスティックが交互レンダーのたびに発火、実額の数倍に膨張。→ セッション別台帳形式（1行目=日付、以降 `session_key|banked|latest`）に変更。テストで非水増し・/clear時の繰越の両方を確認。
2. **ps1: JPY取得ジョブが完了前に死ぬ** — `Start-Job` の子は親プロセス終了時に破棄される。statusline は即 exit するためフェッチが完了しない。→ `Start-Process` によるデタッチドワーカー（`-FetchJpyRate` / `-ComputeCostFor` 自己再帰起動）に変更。
3. **ps1: 0% を欠損扱い** — `-not $pct` は 0 で真。→ `$null -eq` 比較に統一。
4. **Bedrock モデルID が価格表に不一致** — `us.anthropic.claude-*-YYYYMMDD-v1:0` のリージョン接頭辞と `-vN:0` 接尾辞が未処理で全部デフォルト(sonnet)価格に落ちていた（Opus で約4割過小推計）。→ 正規化を拡張。opus $5/1M + sonnet $3/1M の合成transcriptで $8.00 を確認。

## パフォーマンス（修正済み）

5. ps1: コスト推計が毎レンダー同期実行 → バックグラウンドワーカー + キャッシュ化。
6. bash: 初回キャッシュミス時に同期計算で描画ブロック → 完全バックグラウンド化（初回のみ Cost 非表示）。jq 2段パイプ+slurp → `jq -Rn 'reduce inputs…'` ストリーミング1回に。
7. オフライン時に30秒ごと curl 無限再試行 → 失敗マーカー(`jpy_rate.fail`)で1時間バックオフ。stale レートは表示継続。
8. 毎レンダーのキャッシュ書き込み → 値が不変かつ新鮮なうちはスキップ。

## 堅牢性（修正済み）

9. gauge / cost_estimate キャッシュが cwd キーで同一ディレクトリ複数セッション時に混線・スラッシング → session_id / transcript_path キーの複数行形式に。tmpファイルはPIDサフィックスで衝突回避。ロックは transcript ごと(cksum/MD5サフィックス)。
10. jq 不在時に無言で空表示 → モデル名 + `[statusline: jq not found]` を表示して exit 0。
11. ¥500予算・JPY固定 → `CC_STATUSLINE_BUDGET_JPY` / `CC_STATUSLINE_JPY=0` で設定可能に。
12. ロケール（カンマ小数点圏）で printf %.2f が失敗 → `export LC_NUMERIC=C`。

## コード品質・インストーラ（修正済み）

13. ▰▱バー描画の重複 → `draw_bar` / `New-Bar` 関数に集約。
14. install.sh: カレントディレクトリ前提の `cp` → `cd "$(dirname "$0")"`。settings.json のバックアップ(.bak)と jq 失敗時の中途半端インストール防止を追加。
15. uninstall.sh: `.tmp` 残骸・`jpy_rate.fail`・`cost_estimate.*.lock` の削除漏れ → 追加。settings.json バックアップも追加。

## テスト結果（bash 版）

| テスト | 結果 |
|---|---|
| 通常レンダー（subscriber, 全ゲージ） | ✅ |
| 複数セッション交互レンダー7回 → Today = 実額合計 | ✅（旧コードでは毎回+$5膨張するケース） |
| /clear 相当のコスト減 → banked に繰越 | ✅ |
| Bedrock/Vertex ID 正規化コスト推計（期待$8.00） | ✅ 初回スキップ→バックグラウンド計算→2回目表示 |
| jq 不在フォールバック | ✅ |
| `CC_STATUSLINE_BUDGET_JPY=0` / `CC_STATUSLINE_JPY=0` | ✅ |
| 本番シンボリックリンク (`~/.claude/statusline.sh`) 経由 | ✅ |

## 残タスク

- [ ] statusline.ps1 の Windows 実機検証（Start-Process ワーカー、EncodedCommand 不使用の -File 起動、パスにスペースを含むユーザー名）
- [x] ~~git commit~~ → 完了（2026-07-14、両リポジトリともpush済み。上記参照）
- [ ] Mac側の `dotfiles-claude` pull（別課題、[[project_mac_ubuntu_config_drift]]参照。今回の修正はMac側に未反映）
