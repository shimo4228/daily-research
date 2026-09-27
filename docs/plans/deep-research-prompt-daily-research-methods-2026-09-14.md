# ディープリサーチ依頼: 個人向け日次リサーチシステムの「リサーチ方法」の現時点で最良の設計

作成 2026-09-14。依頼者は下記のシステムを作り直そうとしている。求めるのは、prompt の書き方だけでなく、**リサーチ方法そのものの設計**（工程の分け方、問いの立て方、検索と検証、合成と執筆、run 間の記憶、評価）について、2026-09 時点で根拠のある最良の形を、一次資料に基づいて示すこと。設計案は出してよい。ただし採否は依頼者が決めるので、各案の根拠・費用・弱点を並べ、推奨には理由と失効条件を付けてほしい。

## 対象システム（変えてよい前提と、変えない前提を分けて書く）

**変えない前提**
- 毎朝 05:00 に macOS の launchd から無人で起動し、Claude Code の `claude -p`（非対話、subscription 経由。外部 API key・検索 API・ベクトル DB・MCP サーバは使わない）で動く。使えるツールは WebSearch / WebFetch / Read / Glob / Grep と、指定パスへの Write / Edit。Bash は無い。
- 7 本のリサーチラインがあり、各ラインは依頼者の研究 repo に 1 対 1 対応する。ラインの主題: agent の知識蓄積サイクル（skill library、continual learning、agent harness）、contemplative alignment（AI alignment × 瞑想・仏教）、AI accountability と規制実務、著者戦略（LLM 経由で idea が届く経路、識別子・アーカイブ基盤）、仏教アビダルマ × 計算論的現象学（active inference、GWT、IIT）、需要側フロンティア（「AI に頼みたいことが尽きた」等の一人称証言、taste / agency 論）、AI 活用のエッジ事例（1 人 + agent 群で組織相当を回す、全面委譲の生活、限界の観測）。
- run は対象 repo を作業ディレクトリにして起動でき、repo の運用文脈（タスク台帳、未解決の問い、README、CLAUDE.md、ADR）を読める。repo は read-only。
- 出力は日本語の解説レポートで、読者は依頼者 1 人。毎朝合計 10〜15 分で読む。読者の反応は記録されない。承認要求・作業指示・「〜すべき」は書かない。主語は外部の出来事で、repo への含意を添える。
- **「面白さ」や読者の主観を数値化・採点する評価は設計しない**（依頼者の方針。過去にそれで壊れた）。
- 費用の目安は 1 日 $10〜15、1 run 25 分程度、1 日 3 run。これを大きく超える設計は「超える理由」を明記して提示してよい。

**変えてよい前提（現行の形であって、設計上の前提ではない）**
- 現行は 1 run = 単一 agent（Opus、最大 55 turn）が「文脈読込 → 監視 source の差分確認 → テーマ候補 2〜3 件から 1 件選択 → 一次ソースまで検索 → 執筆 → state 更新」を 1 回で行い、その後に別プロセス（Sonnet、研究文脈なし）が可読性だけを改稿する。工程の分割（探索と執筆の分離、subagent、複数 pass）、文脈を渡す量と時期、run の粒度（1 ライン 1 run か、まとめて 1 run か）は変えてよい。
- 現行の state: ラインごとの `watched-sources.md`（監視 source と last-seen）、`playbook.md`（日付付きの判断メモ、delta 追記のみ）、全ライン共通の過去テーマ履歴 JSON（重複防止）。これも設計対象。
- 現行の輪番: 7 ラインから 1 日 3 本を決定論的に選ぶ。各ラインは 2〜3 日に 1 回。周期・重み付けは設計対象。

**運用履歴（設計に効く事実）**
- 2026-05 から 5 本/日で 3 か月回して「似た題材が続く」「読む量が多い」と感じた。08-13 に 1 本/日輪番へ。09-06 に repo 文脈を渡さない自由探索版（探索 agent と編集 agent を分離、読者紹介だけを渡す）へ再編したが「無関係な話題ばかり」になった。今回は repo 文脈を渡す方式へ戻し、探索をもう少し発散させたい。
- 飽和は repo 文脈を渡す前（固定ドメインの時代）から起きていた。したがって「文脈を渡すから収束する」は依頼者の仮説であり未検証。文脈の渡し方以外の原因（同じモデルが同じ source を引く、日次という頻度、題材領域の有限性）も候補。
- 過去 3 回、自由探索ラインを作っては廃止している。

## 既に読んだ一次資料（同じ内容の再報告は不要。これより深く、またはこれに無いものを）

- Anthropic「How we built our multi-agent research system」(2025-06): orchestrator–worker、effort scaling（単純事実 3〜10 call、比較 10〜15）、start wide then narrow、source quality heuristics、LLM-judge rubric（factual accuracy / citation accuracy / completeness / source quality / tool efficiency）、小規模 eval から始める
- LangChain Open Deep Research の prompts.py（archived）: clarify → brief 化（未指定次元は open-ended と明示）→ supervisor 委任 → researcher の停止条件（独立 3 源 / 直近 2 検索が同内容 / 上限）→ verbatim 圧縮 → 番号付き出典の report
- GPT Researcher prompts.py: planner / executor、curate_sources（定量データ優先、要約しない）、report（自分の具体的見解を持て、一般論に逃げるな）
- STORM / Co-STORM（NAACL 2024 / EMNLP 2024）: perspective-guided question asking、simulated conversation、moderator による未使用情報からの問い、mind map
- SIFT（Mike Caulfield 2019）: Stop / Investigate the source / Find better coverage / Trace to origin、lateral reading
- K-Dense scientific-agent-skills: hypothesis-generation（観察の凍結、rivals 先出し、dated evidence boundary、「探索範囲内で見つからなかった」語法）、research-lookup（矛盾・null 証拠を残す）、literature-review（検索語と日付の記録）
- Orchestra AI-research-SKILLs: brainstorming-research-ideas の 10 lens、autoresearch の inner / outer loop（DEEPEN / BROADEN / PIVOT / CONCLUDE）、research-manager の provenance tag と exploration tree
- HumanLayer research_codebase（documentarian）、web-search-researcher、design-control-loop（sensor / controller / actuator、memory file は次回の選択を変える feedback だけ、部品をローカル単体実行してから配線）
- karpathy autoresearch program.md（編集対象と評価の分離、固定予算、keep / discard 記録）、Superpowers systematic-debugging、OpenSpec explore

## 調べてほしいこと

### 0. 設計全体: 2026-09 時点で「個人向け・無人・日次・repo 文脈つき」のリサーチ方法はどう設計されているか
- 公開されている deep research 系（OpenAI / Google / Perplexity / Anthropic / Kimi / OSS）の工程設計と、その評価（Deep Research Bench、BrowseComp、DeepResearchGym 等）で、品質に効いた設計要因と効かなかった要因。単一 agent と orchestrator–worker の比較実証。
- 「探索と執筆の分離」「計画と実行の分離」「検証を別プロセスにする」の各分割について、効果の実証と、分割が害になる条件。
- 個人や小チームが日次・週次で回している自動リサーチ（newsletter 自動化、personal intelligence briefing、research agent の長期運用記録）で、設計と運用の記録が公開されているもの。長期運用で何が壊れたか。
- 上の「変えない前提」の下で成立する設計の候補を 2〜3 案、工程図つきで示す。各案について、1 run の turn / 時間 / 費用の見積、必要な state、弱点、それを支持する根拠。

### A. 題材の発散: 毎回似た題材に収束しない問いの立て方
- STORM の perspective 生成と question asking の実際の prompt と、depth / breadth への効果の中身。Co-STORM の moderator の仕組み。
- intelligence analysis の structured analytic techniques（Heuer の Analysis of Competing Hypotheses、Key Assumptions Check、Devil's Advocacy 等）のうち 1 run 内で使える形のもの。
- information foraging theory、serendipity の設計研究、exploration–exploitation を反復する日次ブリーフに適用した先例。
- newsletter や intelligence briefing の編集者の題材選定として文書化・評価されているもの（飽和の避け方、固定読者 1 名の場合）。
- context / prompt が探索の多様性を下げるという実証と、文脈を渡しつつ多様性を保つ手法（query diversification、negative constraints、randomized perspective、過去テーマの否定制約 等）。文脈を「いつ」渡すか（選定前か、選定後か）の比較があれば特に。

### B. 検索戦略と予算
- 停止規則（いつ検索をやめるか）の根拠ある設計。turn 予算と品質の関係の実測。
- 日英以外の言語圏、検索エンジンに出にくい source（コミュニティ、preprint、規制文書、GitHub issue、Discord / Slack の公開ログ）の取り方。
- WebSearch / WebFetch しか無い制約での実践的な工夫（site 指定、日付指定、一次ソース直行、RSS / Atom の直接 fetch 等）。

### C. 出典評価と検証
- SIFT / lateral reading の効果研究（Wineburg & McGrew 等）とその後の批判。
- Wikipedia の Reliable Sources / Verifiability、IFCN 系 fact-check の手順、Verification Handbook（Silverman）などから、agent に落とせる手順。
- 「見つからなかった」の報告規範（absence of evidence）。
- 自己汚染対策（運用者自身の成果物・過去レポート・自分の生成物を外部の動向と誤認しない）の先例。
- 引用の正確さ（引用が本文の主張を支えているか）を機械的または別プロセスで検証する設計の実証。

### D. 合成と執筆
- explanatory journalism、intelligence briefing の書式（BLUF 等）、科学ジャーナリズムの「事実と解釈の分離」規範のうち、評価や採用実績があるもの。
- LLM 生成レポートの品質に効くと実証された執筆規則（構成の自由度、長さ、自己言及の禁止、引用の置き方、「自分の見解を持て」の効果、rivals / 反対材料の節）。
- 「含意」の過剰主張を避ける規範（政策分析、諜報分析の estimative language を含む）。
- 固定読者に毎朝届く連載で、繰り返し説明・定型句の疲労を避ける方法。

### E. 反復運用の記憶
- agent の長期記憶・playbook・watched sources について、飽和や自己強化を避ける設計の実証。何を残し、何を残さないか。
- 予測の失効管理（Tetlock の forecasting 実践、resolution の記録）を「日付付き機会メモ」に応用した例。
- 過去テーマとの重複判定を topic 粒度でなく問い粒度で行う方法。

### F. 評価と故障モード（読者の主観採点は除く）
- 主観を使わずに回る評価: citation accuracy、source quality、繰り返し率、一次ソース到達率などを別プロセスや機械で測る設計の実証と限界。
- deep research agent の既知の故障モード（幻覚引用、同じ source への収束、冗長化、自己確認バイアス、無人運用での silent failure）と、緩和できたと報告されているもの。

## 出力の形式

1. **設計候補 2〜3 案**（領域 0）: 工程図 / 各工程の担当（単一 agent か、別プロセスか）/ 渡す文脈と時期 / state / 1 run の見積（turn・分・$）/ 根拠 / 弱点 / どの条件で選ぶか。
2. **手法ごとの記録**（領域 A〜F）: 手法名 / 出所（誰が・いつ・一次 URL）/ 何を具体的に指示しているか / 効果の根拠（種別: 実験・ベンチマーク・採用実績・標準文書・意見）/ 上のシステムでの落とし方（設計への反映か、prompt の 1 規則か）/ 他の手法との衝突 / 確認日。
3. **推奨**: 1 案を選ぶなら何か。選ぶ理由、現行から残す部分、捨てる部分、推奨が無効になる条件（失効条件）。
4. **prompt に入れる規則の候補一覧**: 根拠の強い順。各 1 行 + 出所。
5. **衝突と未解決**: 手法どうしが逆を言っている点、制約と噛み合わない点、実証が無く意見しか見つからなかった点。
6. **探して見つからなかったもの**: 検索語と範囲を添えて。「先行例なし」とは書かない。
7. 出典はすべて一次資料（論文、公式ブログ、リポジトリの実ファイル、方針文書）へのリンク。二次記事の要約を根拠にしない。各出典に確認日を付ける。agent 固有の知見は 2025 年以降を優先し、SIFT や ACH のような古典手法は原典で可。
8. 日本語で書く。出典の原文引用は英語のままでよい。長さの上限は設けない。

## やらないでほしいこと

- 外部 API key・検索 API・ベクトル DB・MCP サーバ・multi-agent framework の導入を前提にした設計。Claude Code 単体で動くこと。
- 読者の主観的な面白さを採点する評価設計。
- 根拠の無い断定。意見しか無い点は意見と書く。
