# 運用手順書

> daily-research 自動化システムの運用手順。

## デプロイ

### 初期セットアップ

```bash
# 1. プロジェクトに移動
cd /path/to/daily-research

# 2. スクリプトに実行権限を付与
chmod +x scripts/daily-research.sh
chmod +x scripts/check-auth.sh

# 3. 認証を確認
./scripts/check-auth.sh

# 4. テンプレートから plist を作成
cp com.example.daily-research.plist com.daily-research.plist
# com.daily-research.plist を編集: YOUR_USERNAME を macOS ユーザー名に置換

# 5. launchd シンボリックリンクを作成
ln -sf "$(pwd)/com.daily-research.plist" \
       ~/Library/LaunchAgents/com.daily-research.plist

# 6. ジョブをロード
launchctl load ~/Library/LaunchAgents/com.daily-research.plist

# 7. 登録を確認
launchctl list | grep daily-research
```

### 変更後の更新

```bash
# スケジュールやパスを変更した場合は plist をリロード
launchctl unload ~/Library/LaunchAgents/com.daily-research.plist
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

設定・プロンプトの変更（`config.toml`, `prompts/*`, `templates/*`）はリロード不要。次回実行時に自動反映される。

### 手動実行

```bash
# launchd 経由
launchctl start com.daily-research

# 直接実行
./scripts/daily-research.sh
```

## 監視

### ログの場所

| ログ | パス | 保持期間 |
|------|------|---------|
| アプリケーションログ | `logs/YYYY-MM-DD.log` | 30日（自動ローテーション） |
| launchd 標準出力 | `logs/launchd-stdout.log` | 手動クリーンアップ |
| launchd 標準エラー | `logs/launchd-stderr.log` | 手動クリーンアップ |

### 日次チェック

```bash
# 今日のログを確認
cat logs/$(date +%Y-%m-%d).log

# レポートが生成されたか確認（config.toml の vault_path を使用）
ls -la "/path/to/your/obsidian/vault/daily-research/"

# launchd ジョブの状態を確認
launchctl list | grep daily-research
# 終了コード 0 = 前回の実行が成功
```

### ヘルスチェック指標

| 確認項目 | コマンド | 期待結果 |
|---------|---------|---------|
| ジョブ登録済み | `launchctl list \| grep daily-research` | 終了ステータス 0 の行 |
| 認証有効 | `./scripts/check-auth.sh` | "OK: Claude authentication is valid" |
| 今日のログが存在 | `ls logs/$(date +%Y-%m-%d).log` | ファイルが存在 |
| ログに成功メッセージ | `grep "Completed successfully" logs/$(date +%Y-%m-%d).log` | マッチあり |
| レポートが生成済み | `ls <vault_path>/daily-research/$(date +%Y-%m-%d)_*` | 2ファイル |

## よくある問題と対処法

### 1. OAuth トークン期限切れ

**症状**: ログに `ERROR: Claude authentication may have expired` が出力される。macOS 通知が表示される。

**原因**: Claude の OAuth トークンは約4日で期限切れになる。

**対処**:
```bash
# Claude CLI を対話モードで起動してトークンを更新
claude
# 認証プロンプトが表示されたら完了させて終了
# 確認:
./scripts/check-auth.sh
```

**予防策**: 週2回以上 `claude` を対話モードで起動する。

### 2. `claude` コマンドが見つからない

**症状**: ログに `ERROR: claude command not found in PATH` が出力される。

**原因**: launchd 環境の PATH に Claude CLI のインストール先が含まれていない。

**対処**:
```bash
# claude のインストール先を確認
which claude

# そのパスが daily-research.sh の PATH export と
# plist の EnvironmentVariables PATH に含まれているか確認
```

### 3. ロックファイルによる実行ブロック

**症状**: ログに `ERROR: Another instance is running (PID: ...)` が出力される。

**原因**: 前回の実行がまだ実行中、またはクラッシュしてクリーンアップされなかった。

**対処**:
```bash
# PID が実際に実行中か確認
ps aux | grep daily-research

# プロセスが存在しない場合、古いロックファイルを削除
rm -f .daily-research.lock
```

### 4. タイムアウト（終了コード 124）

**症状**: ログに `Timed out after 1800s` が出力される。

**原因**: Claude の実行が30分を超えた（Web取得やリサーチが長引いた可能性）。

**対処**: `scripts/daily-research.sh` の `TIMEOUT_SECONDS` を増やす（現在: 1800 = 30分）。

### 5. `ANTHROPIC_API_KEY` が設定されている（従量課金）

**症状**: Anthropic ダッシュボードに予期しない API 課金が発生。

**原因**: `ANTHROPIC_API_KEY` 環境変数が設定されていて、Max プランを迂回している。

**対処**: スクリプトは `unset ANTHROPIC_API_KEY` を実行する。それでも課金される場合、シェルプロファイル（`~/.zshrc`, `~/.bashrc`）の export を確認する。

### 6. レポートが Obsidian に表示されない

**症状**: スクリプトは正常終了するがレポートが Obsidian に表示されない。

**原因**: iCloud 同期の遅延、または vault パスの変更。

**対処**:
```bash
# vault パスが config.toml と一致しているか確認
grep vault_path config.toml

# ディスク上にファイルが存在するか確認（vault_path を使用）
ls "/path/to/your/obsidian/vault/daily-research/"

# iCloud 同期を促す: iOS のファイルアプリを開くか、しばらく待つ
```

### 7. テーマの重複

**症状**: 最近と同じテーマのレポートが生成される。

**原因**: `past_topics.json` が正しく更新されていない、またはスコアリング基準の調整が必要。

**対処**:
```bash
# past_topics.json を確認
cat past_topics.json | python3 -m json.tool

# 破損している場合はバックアップから復元
cp past_topics.json.bak past_topics.json
```

## ロールバック手順

### 設定変更の取り消し

```bash
git diff config.toml
git checkout config.toml
```

### past_topics.json の復元

```bash
cp past_topics.json.bak past_topics.json
```

### 自動実行の停止

```bash
launchctl unload ~/Library/LaunchAgents/com.daily-research.plist
```

### 自動実行の再開

```bash
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

## スケジュール

| 時刻 | アクション |
|------|-----------|
| AM 5:00 | launchd が `daily-research.sh` を実行 |

5:00 に Mac がスリープ中だった場合、復帰時に launchd がジョブを実行する（`StartCalendarInterval` の仕様）。
