# Daily Research

次に考えたいこと・試したいことを発見する、朝の日本語リサーチレポート。
主役1本と短い発見を通じて、知らなかった実例、研究、問いに出会います。
今のプロジェクトにすぐ使えることは必須条件にしません。

[English](README.md)

## 仕組み

Claude Opusが短い読者紹介から外部を探索します。別のOpusが調査素材と直近30日分の記事索引を受け取り、追加調査も行いながら一号を編集します。材料に応じて短報だけの日や休刊も選べます。

両工程は専用の作業場所で`--safe-mode`を使い、WebSearch/WebFetchだけを利用します。
モデルが返すJSONをPythonが検査・保存します。探索には研究repoや蓄積したplaybookを渡しません。
読者紹介は、実際の記事への本人の反応を確認して更新します。

通常号・短報号はObsidian Vaultへ`YYYY-MM-DD_discovery_edition.md`として保存し、休刊案内は非公開の実行記録に残します。当日分を新しく保存した場合は既存のwiki ingestへ渡します。付属のlaunchd設定は毎朝5時実行です。

## 始める

Bash、Python 3.11以上、GNU `timeout`（Homebrewのcoreutils）、認証済みのClaude Code CLIが必要です。CLIは`--safe-mode`と構造化JSON出力に対応する版を使用します。Claudeのサブスクリプション認証を利用します。

```bash
cp config.example.toml config.toml
cp reader-profile.example.md reader-profile.md
# config.tomlのVaultパスとreader-profile.mdを編集
./scripts/daily-research.sh --preview
```

試作はrepo内の非公開作業領域へ保存し、Vault・本番履歴・wikiには混ぜません。
通常の保存は`--preview`なしで実行します。`--date YYYY-MM-DD`で号の日付、`--config PATH`で設定を指定できます。当日以外の日付には`--preview`が必要です。過去日付を指定しても、当時のWeb環境を再現するものではありません。

スケジュールと復旧は[運用ガイド](docs/RUNBOOK.ja.md)、検証は[開発ガイド](docs/CONTRIB.ja.md)、判断の記録は[ADR-0016](docs/adr/0016-discovery-first-edition.md)を参照してください。

## 読みながら確かめる

1週間後に「続きを知りたくなったもの」「新しく考え始めたこと」「また同じ話と感じたもの」を振り返ります。
候補素材も残すため、見つけられなかったのか、編集で落としたのかを確認できます。本数・出典数を面白さの指標にはしません。

旧graphと研究状態は履歴として保存します。この構成による改善は、実際の記事と読者の反応で確かめます。
