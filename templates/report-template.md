<!-- origin: shimo4228 -->
# 出力の読者契約

完成原稿はJSONで受け取り、`scripts/lib/discovery.py` がMarkdownにします。
JSON schemaとfrontmatterの実装上の正本も同モジュールです。

通常号は主役1本と短い発見、短報号は短い発見のみ。見出しと文章構成は題材に合わせます。
読者は探索手順を知らなくても読めること。長さの目安と編集判断は
[編集プロトコル](../prompts/editorial-protocol.md)を参照してください。

保存側がdate/category/tags/topic/sources/actionableを付け、末尾に`## ソース`を生成します。
実在する締切がある場合に限り`## 機会メモ`が入ります。休刊は非公開の実行記録に保存し、
Vaultへの記事保存・wiki ingestの対象にしません。
