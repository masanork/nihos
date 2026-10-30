# nihosのOS書籍

『小さなOSを育てる — ZigとRISC-Vで学ぶ、実機のしくみと設計判断』の原稿と組版環境です。nihosを教材に、OSの仕組みと実機での設計判断を学びます。

序章の問いを各章へつなぎ、役割と保護、モデルと実機、応答と期限、共有とメッセージ、データの寿命と割当方式を比較しながら実装を読みます。後半では、日本語フォント、無線通信、I/Oの寿命、保存と復旧、部分更新、重い計算サービス、SQLiteの保存を経て、ICカード端末の総合事例へ進みます。IMUと音声DMAもI/Oの具体例として扱います。

- [編集資料・企画案と類書調査](proposal.md): 読者、差別化、目次案、演習、エコシステムへの導線。本文には収録しません。
- [OS教科書のシラバスとフィットギャップ](syllabus-fit-gap.md): 二十章をOS基礎課程と照合し、本文の不足、nihosの実装・統合課題、比較説明に留める範囲を整理した編集資料。
- [本文](ja/preface.md): 序章と、機械の基礎、境界・OS環境の比較からタスク、通信、保存、端末、言語選択へ進む二十八章。
- [序章 小さなOSを学ぶということ](ja/why-os.md): MeOSに惹かれた出発点、開発中の発見、現在の設計上の問いを分け、OSとAIと学ぶ意味を考えます。
- [CPUとメモリ、機器の仕事を追う](ja/machine-basics.md): バイトと番地、CPUとレジスタ、スタック、メモリマップとMMIO、ポーリングとIRQ、DMA、キャッシュを、入力から画面更新までの例と紙上演習で学びます。
- [M5Stackで動くOSとアプリ環境を見渡す](ja/m5stack-ecosystem.md): FreeRTOS、MeOS、NuttX、Zephyr、Tactility、tab5-os、MicroHydra、UIFlow、M5Launcher、NOMMU Linuxとエミュレータを、機種と実行方式から比較します。
- [OSを何で書くか](ja/os-languages.md): アセンブリ、PL/I、C/C++、Lisp、Mesa/Oberon、Singularity、RustからZigの利点と限界を考える。Singularityの実体験とNGSCBについての伝聞を交え、言語・検証・開発環境の関係も考える。
- [Zigで書かれたカーネルが動き始めるまで](ja/native-entry.md): スタックと初期値、最初の例外復帰、ELF配置の実験。
- [割り込まれたプログラムを再開する](ja/task-lifetime.md): タイマー、保存フレーム、sleep、終了と回収、generation。
- [スケジューラは公平か](ja/scheduler-fairness.md): 飢餓の反例、TLA+の有限モデル、Zigでの再生と回帰テスト。
- [タスクの実行と、壊せる範囲を分ける](ja/process-isolation.md): プロセスと実行単位、U-modeとPMP、ECALL、故障の回収、CLICと同期バスエラーの実機検証。
- [別のCPUへ仕事を渡して待つ](ja/messages-and-waits.md): SPSC、公開と通知、IPI、WFI、待機直前の通知。
- [メモリを返して使い直す](ja/reusable-memory.md): owner、buddy heap、断片化と結合、古い解放の拒否。
- [浮動小数点の状態と言語の境界](ja/floating-and-abi.md): FPU状態、命令監査、ILP32FとC adapterを扱う補足。
- [使えるメモリになるまで](ja/psram-and-evidence.md): PSRAMの段階的検証、実機識別失敗、address設定とcache同期の修正からSQL実行まで。
- [既存のCライブラリを迎える](ja/c-library.md): SQLiteのallocator、owner、shutdown、メモリ不足からの回復とnative実行の範囲。
- [重い計算をOSサービスにする](ja/pqc-service.md): PQC実験を題材に、入力snapshot、専用worker、取消し、回収失敗、SRAM・Flash配置を扱う発展事例。
- [文字が画面に現れるまで](ja/drawing-text.md): ASCII grid、RGB565、部分更新、scroll、cacheとDMAの受渡し。四象限のタッチ実習と、明示的な離指・未更新sampleの区別。
- [日本語フォントを載せる予算](ja/japanese-fonts.md): FreeType/HarfBuzz、複数session、extent group、確保失敗、hintingとRV32 stack、workerの寿命。
- [通信相手は、別の計算機](ja/networking.md): P4–C6、SDIOのdoorbell、DHCP更新・失効、IPv6、BLEのcreditと完了。RTCの妥当性を扱うコラム。
- [タスクが終わっても、仕事は終わらない](ja/io-lifetime.md): brokerのpin、強制終了、タイマーの寿命、SDの抜去・再挿入。FatFs/VFS/RPC、IMUの連続読取り、有限音声DMAの終了と返却。
- [保存できた、と言ってよいのはいつか](ja/durable-storage.md): COW、二つのroot、成功通知、故障モデル、負例、file backendとreader保護。
- [20バイト直すために、何バイト書くか](ja/partial-updates.md): streaming、共有page map、GC、探索予算とcache。疎な伸長・truncate・一括更新の書込み比較。
- [SQLiteの保存を成立させる](ja/sqlite-persistence.md): コピー所有service、VFS、実SQLiteのPERSIST回復、syncの負例、cache比較、上限付きallocatorと永続DBのOOM再生。
- [ICカード端末としてつなぐ](ja/card-terminal.md): USB/CCID/APDU、session、一回の送信予算、画像移植、正常cleanup後の公開と消去。実習は模擬transportのみ。
- [おわりに](ja/afterword.md): 実装と実験で学んだことを、次の変更へつなげます。
- [実習環境](ja/practice-notes.md): 必要なツール、参照版、測定の条件。
- 索引: [用語定義](index-terms.cjs)と本文から生成。PDFではページ番号、Web版では章へのリンクを表示します。
- [章の雛形](chapter-template.md): 新しい章を育てるときの共通項目。

## PR #76を反映した版

書籍は前回刊行版`378ead82`を継承し、カーネルはPR #76のmerge `d86fcf0`へ固定します。通常ワーカーのM-modeと、CPU0診断用のU-mode保護タスクを区別し、全アプリがプロセス化されたとは扱いません。

| 影響 | 反映先 |
| --- | --- |
| 実行単位と保護単位、変換とアクセス権の区別 | 新章「タスクの実行と、壊せる範囲を分ける」、境界、管理表、PSRAM |
| 安全な例外入口、復帰権限、モード切替とタスク切替 | 起動、タスクの寿命、新章の復帰図 |
| スカラECALLとポインタ付き呼出しの違い | CPU間通信、Cライブラリ、浮動小数点ABI、SQLite |
| 故障後のclose・回収・reap・世代更新 | タスクの寿命、新章の回収図、I/Oの寿命 |
| 既存の所有権や資源隔離との関係 | メモリ割当、PQC、ファイルのFD、言語選択 |
| v1.3のCLIC/SBEと証拠の範囲、費用 | 新章、実習環境、編集レビュー、シラバス対応 |

新章の実習はホスト上のPMPエンコーダと保存済みログの読み取りです。物理Flashへの書込みを自動実行しません。公開サービス、任意バイナリのローダ、複数threadのprocess資源共有、DMAの隔離は別の課題として残します。

## PDFとWeb版の生成

Node.js 22.13以降とnpmを使用します。依存のバージョンはpackage-lock.jsonで固定します。

```sh
cd docs/book
npm ci
npm test
npm run check
npm run build
npm run build:web
npm run preview
```

PDFは `output/pdf/nihos-book-sample.pdf`、Web Publicationは `output/web/` へ生成します。初回のPDFビルド時にはVivliostyleがブラウザを取得する場合があります。Webの確認は `npx --no-install vivliostyle preview -c vivliostyle.config.cjs`、または生成先をHTTPで配信して行います。HTMLの目次は `output/web/_build/ja/toc.html` にあります。

`npm run check` は原稿、章参照、リポジトリ内の参照先、コード抜粋のアンカーを検査し、`_build/` に原稿と出典情報を生成します。OSの動作は検証しません。各章の実験は別に実施します。プレビュー中に原稿やソースを変更した場合は、別のターミナルで `npm run check` を再実行してください。

間接依存の既知の脆弱性に対して `package.json` の `overrides` を指定しています。依存更新時は `npm audit` とPDF・Webの両方のビルドで互換性を確認します。

## 原稿を増やす

`book.cjs` が章順の正本です。`ja/<id>.md` を作り、同ファイルにentryを追加します。章のH1には章番号を付けず、章間参照は `{{ch:<id>}}` と書きます。目次・番号は生成物にだけ挿入します。

リポジトリ内の資料には `[説明](repo:docs/architecture.md)` の形でリンクできます。前処理が存在を確認し、ビルド時点のコミットに固定したGitHubリンクへ変換します。コードは `{{snippet:<id>}}` で取り込み、抜粋の範囲は `scripts/prepare.mjs` で指定します。ソース変更でアンカーが見つからない場合は、古いコードを黙って掲載せずビルドを停止します。

`book.cjs`の`kernelRevision`が、通常のリポジトリ参照と既定のコード抜粋を固定します。本版はPR #76を含む`d86fcf0`を使い、書籍の編集コミットと区別します。指定したコミットのGit objectから読み出すため、別worktreeの作業中ソースを誤って掲載しません。個別の`git:`参照や抜粋の`revision`は、従来どおり各実験の版を優先します。

`_build/source.json` はカーネル側の`revision`、書籍の`bookRevision`と未コミット変更の有無、原稿の変更有無、各原稿・参照資料・抜粋元ファイル・抜粋コードのSHA-256を記録します。ビルド後にPDF/Webそれぞれの出力先へ自動でコピーします。本文に資料番号や巻末のファイル一覧は挿入しません。発行時には原稿、ソース、実験記録、toolchainを対応づけた版を固定します。

後続の事例では `[説明](git:<40桁commit>:<path>)` で別コミットの資料を参照できます。前処理がGit objectの存在を確認し、その版の内容をhashへ記録します。抜粋にも`revision`を指定できます。公開の追跡済み`origin/main`に含まれる変更のない参照資料だけを本文のリンクとし、それ以外は説明の文言だけを表示します。生成に別worktreeのファイルは不要ですが、参照するGit objectは必要です。公平性・Cライブラリ・文字描画と後半の事例は個別の版で実験し、本文の基準版を変更したりカーネルを統合したりはしません。各実機記録も、その記録の候補と設定に限定して読みます。

## データ構造と状態遷移の図

図の元データは`figures/*.mmd`のMermaidです。本文の`{{figure:<id>}}`を前処理でSVGと図番号へ変換し、同じ図をPDFとWebへ収録します。生成済みSVGとmanifestも保存するため、通常の原稿チェックには図の再描画用ブラウザは不要です。

図を編集したら`npm run figures`で再生成し、`npm run check`を実行します。再描画にはPuppeteerが使うChromeが必要です。インストール済みのChromeを使う場合は`PUPPETEER_EXECUTABLE_PATH`で実行ファイルを指定できます。必要なら`npx --no-install puppeteer browsers install chrome`で用意します。

各図には`accTitle`（図題）と`accDescr`（代替説明）を必須とします。構造図の矢印は参照や所有、状態遷移図は操作と条件、シーケンス図は時間順を表します。実装済みの経路、比較モデル、将来案の区別は本文にも記します。色だけで意味を分けず、A5で文字が読める大きさにします。

`npm run check`は元データ・設定・Mermaidの版・SVGのhashを照合し、古い図や不明な参照を拒否します。`source.json`に図の出典・hash・使用章・図番号を記録します。SVGは外部画像やJavaScriptへ依存せず、文字をtextとして保持します。描画後はPDFの該当ページとWebの両方で、重なり・欠け・文字サイズを確認します。[Mermaid公式の代替説明](https://mermaid.js.org/config/accessibility)と[CLI](https://github.com/mermaid-js/mermaid-cli)を使用しています。

## 索引と奥付の日付

`index-terms.cjs` に用語、読み、表記の別名を指定します。前処理がMarkdownを構文解析し、各章の最初の該当箇所へ索引のアンカーを入れます。コードブロック、リンク先URL、HTML属性は検索対象に含めません。本文中のコード表記は検索しますが、その内容は変更しません。本文にない用語は索引に出しません。

索引は欧字・記号と五十音順に並びます。PDFではCSSの`target-counter`で組版後のページ番号を表示し、Web版では章名から同じ箇所へ移動できます。章の追加、並べ替え、原稿の変更のたびに再生成するので、ページ番号の手修正は不要です。検出した用語と移動先は`source.json`にも記録します。

奥付の`{{build-date}}`はビルド時に日本時間の日付へ置き換えます。日付を固定する場合は、UTCの秒数で`SOURCE_DATE_EPOCH`を指定します。例えば`SOURCE_DATE_EPOCH=0 npm run build`なら、奥付は1970年1月1日になります。これは日付の再現用で、PDF全体のバイト一致を保証するものではありません。

## 参照した組版

monbanの `docs/book/ja/` にあるA5・Markdown・Vivliostyle techbook、章番号生成の運用を参考にしました。このディレクトリのCSSと前処理はnihos用に独立して記述し、monbanの本文・画像・コードはコピーしていません。monbanへのローカルパス依存はありません。

Vivliostyleの設定は[公式設定リファレンス](https://docs.vivliostyle.org/en/cli/config/)に基づきます。テーマはbare package名ではなくインストール済みのローカルパスを指定します。本文のライセンスは、別途の指定がない限りリポジトリの[LICENSE](../../LICENSE)に従います。参照先の書籍・仕様や依存パッケージにはそれぞれのライセンスが適用されます。
