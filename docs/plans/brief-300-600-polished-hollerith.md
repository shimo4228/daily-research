# daily-research の launchd 登録を外す

## Context

運用者が daily-research を 1 から再設計すると決めた。現行の毎朝 5:00 自動実行を止める。
grill-me インタビューは中断（簡素化の設計は新 repo 側で行う）。

## 現状

- `~/Library/LaunchAgents/com.shimomoto.daily-research.plist` → repo 内 plist への symlink
- `launchctl list` に `com.shimomoto.daily-research` が登録済み（最終 exit 0）

## 手順

1. `launchctl unload ~/Library/LaunchAgents/com.shimomoto.daily-research.plist`
2. symlink を削除（repo 内の plist 本体は残す。再登録は `ln -sf` + `load` で戻せる）
3. `launchctl list | grep daily` が空であることを確認

repo のファイルは変更しない。
