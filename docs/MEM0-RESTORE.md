# Mem0 MCP 復元手順

Mem0 Cloud MCP は `claude -p` 実行時の MCP 初期化ハングのため棚上げ中 (2026-02-19)。
Claude Code の MCP 初期化が改善されたら、以下の手順で復元する。

## 復元手順

1. `.mcp.json` を作成:

```json
{
  "mcpServers": {
    "mem0": {
      "command": "npx",
      "args": ["-y", "@mem0/mcp-server@0.0.1"],
      "env": {
        "MEM0_API_KEY": "<YOUR_MEM0_API_KEY>"
      }
    }
  }
}
```

2. API キーは [Mem0 Dashboard](https://app.mem0.ai/) から取得

3. 動作確認: Claude Code の対話セッションで `mcp__mem0__search-memories` が使えることを確認

4. `claude -p` での動作確認: 別ターミナルで短いプロンプトを実行し、MCP 初期化でハングしないことを確認

## 棚上げの経緯

- `claude -p` が `.mcp.json` を読み、npx 経由で MCP サーバーを起動しようとする
- npx の初期化が不安定で、プロセスがハングしタイムアウトする
- launchd 環境では PATH に npx がないため即失敗してスキップ → 問題なし
- 手動実行（ターミナル）では npx があるためハングする
