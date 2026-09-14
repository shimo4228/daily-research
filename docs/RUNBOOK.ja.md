# 運用ガイド

## 実行と確認

```bash
./scripts/check-auth.sh
./scripts/daily-research.sh --preview
./scripts/daily-research.sh --preview --date 2026-09-06
./scripts/daily-research.sh
```

`--config PATH`で別設定を使えます。読者紹介のパスはリポジトリルートからの相対パスです。
既定値は`config.example.toml`を参照してください。試作はログと状態を分け、Vault・本番履歴・wikiへ混ぜません。非公開の実行成果物に探索素材と編集結果を残します。

通常号・短報号は検査後に`<vault_path>/<output_dir>/YYYY-MM-DD_discovery_edition.md`へ保存します。
同日再実行では保存済み記事とwiki取り込みを重複させません。休刊案内は非公開の実行記録とローカル通知に残します。当日以外の日付は`--preview`でのみ実行できます。

本番の実行素材は`state/discovery/runs/`、試作は`.notes/discovery-runs/`に保存します。ログは本番が`logs/YYYY-MM-DD.log`、試作が`.notes/discovery-preview-logs/YYYY-MM-DD.log`です。各実行フォルダには入力・プロトコル・JSON schema・CLI応答・原稿・結果・計測を残します。

## 定期実行

毎朝5時の既存launchdジョブから、`scripts/daily-research.sh`の絶対パスを呼びます。
PATHにClaude、Python 3.11以上、GNU `timeout`（Homebrewのcoreutils）が必要です。
ロックで同時実行を防ぎます。ロックが残って見えても、動いているプロセスを確認してから対処してください。

## 失敗と復旧

認証切れ、CLIの非対応オプション、不正な構造化出力、タイムアウトは実行失敗です。
休刊とは区別します。まず実行ログと各段階の出力を確認してください。タイムアウトは予算終了として再試行しません。それ以外の一時的な実行障害だけ1回再試行し、材料の弱さを理由に再実行しません。未完成の記事は公開しません。

起動できない場合は`claude --help`でsafe-modeと構造化出力の対応を確認し、必要なら対話的に再認証します。隔離を外して回避しないでください。記事保存後にwiki ingestが失敗した場合は、記事を生成し直さず取り込み側のログを確認します。

## 振り返りと戻し方

7日後、変更前の比較用レポートと新しい号を読み、「続きを知りたいもの」「新しく考えたこと」「繰り返し」を本人と確認します。
候補素材から、探索と選定のどちらで外れたかを考えます。読者紹介への反映は本人が採用した変更に限ります。

移行前設定はローカルに退避し、旧コードと追跡済みプロンプトはGit履歴に残ります。
戻す場合はコードと対応する設定を一緒に戻します。過去記事は書き換えず、`graph.jsonld`は凍結を維持します。個人用設定・ログ・調査素材は公開コミットへ含めません。
