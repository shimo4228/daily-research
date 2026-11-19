# plan: API key をやめ、Console の ant ログインで claude -p を API 課金にする

## 背景

- `[billing] mode = "api"` の key（`env_file` の `ANTHROPIC_API_KEY`、jrp と共有）が 2026-11-19 に期限切れになった。
  Console の key は作成時に期限を選び、後から延ばせない（platform.claude.com/docs/en/manage-claude/authentication、2026-11-19 確認）
- Console は key 不要の「自分のマシン」経路として `ant auth login`（ブラウザ OAuth、workspace に限定したトークン、
  `~/.config/anthropic/credentials/<profile>.json` に 0600 で保存し自動更新）を出している

## 実測（2026-11-19、Claude Code 2.1.327、ant 2.11.0）

| 条件 | 結果 |
|---|---|
| `ANTHROPIC_PROFILE=default`、通常の config dir | 成功するが `claude auth status` は `authMethod: claude.ai`（Max）— サブスクで動いた |
| 偽の `ANTHROPIC_AUTH_TOKEN`、通常の config dir | **成功**（保存済みの claude.ai ログインへ黙って落ちる） |
| 空の `CLAUDE_CONFIG_DIR`、資格情報なし | `Not logged in` |
| 空の `CLAUDE_CONFIG_DIR`、偽のトークン | `401 OAuth access token is invalid` |
| 空の `CLAUDE_CONFIG_DIR`、`ANTHROPIC_PROFILE=default`（safe mode の有無とも） | `Not logged in` — profile は読まれない（code.claude.com の authentication の記述と食い違う） |
| 空の `CLAUDE_CONFIG_DIR`、`ANTHROPIC_AUTH_TOKEN=$(ant auth print-credentials --access-token)`、`--safe-mode` | **成功** |

アクセストークンの寿命は発行から 8 時間（`expires_at`）。`print-credentials` は期限切れ間近なら更新してから出す。

## 変更

1. `[billing]` に `credential = "env_file" | "ant"`（既定 `env_file` = 今の挙動）。`ant` は `mode = "api"` のときだけ有効で、
   支出の上限・台帳・`--max-budget-usd`・`classify_exit` の api 扱いはそのまま使う。`ant_profile`（既定 `default`）
2. `lib/billing.sh`: `credential = "ant"` なら key を読まず、`CLAUDE_CONFIG_DIR=$PROJECT_DIR/state/claude-config`
   （空の専用 dir。保存済みの claude.ai ログインへ落ちる経路を断つ）を export し、`billing_refresh_token` が
   `ant auth print-credentials --access-token` の値を `ANTHROPIC_AUTH_TOKEN` に入れる。値は log・通知・引数に載せない
3. `run_claude` の各呼び出しの直前に `billing_refresh_token`（1 run が 8 時間をまたいでも切れない）。取得失敗は E_AUTH と同じ扱いで止めて通知する
4. `lib/env.sh` で `ANTHROPIC_AUTH_TOKEN` と `CLAUDE_CONFIG_DIR` も unset する（親の環境から持ち込まない）
5. `state/claude-config` を呼1・呼2 の Read / Edit deny に足す（`~/.config/anthropic` は既存の `~/.config` deny が塞ぐ）
6. `check-auth.sh` が `credential` を表示し、同じ経路で 1 回叩く
7. テスト（bats: credential 分岐・トークン値が log に出ない・取得失敗の扱い、pytest: `_billing` の検証）と
   README / RUNBOOK / CONTRIB / `config.example.toml` / `llms-full` の billing 節

## やらないこと

- jrp 側の切り替え（別 repo。同じ key を共有しているので同様に止まっている — jrp の session で行う）
- WIF（IdP を持たない Mac では利点がない）

## 判定

- 当日中: `./scripts/check-auth.sh` と `DR_FORCE_TRACK=<line>` の試験 run が API 経路で通り、`state/api-spend.jsonl` に記帳される
- 失効条件: Claude Code が profile を読むようになったら `ANTHROPIC_PROFILE` 経路に寄せて `print-credentials` を外せる。
  ant のログインが無人で更新できなくなる（再ログイン要求）事象が出たら WIF か期限の長い key を再検討する
