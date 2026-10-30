# エディタ拡張のSchemeとLuaおよびUnicode境界

2026年10月25日。エディタの実装前に、拡張言語と文字処理の責任を整理する。

**2026-10-31の採用方針**: 通常起動から `xy` を使い、そのエディタ操作、mode、
keymap、hookとシステム操作の公開はSchemeへ統一する。
[起動面と実装順](xy-architecture.md)を現行方針とする。
以下のScheme/Lua比較は選定の背景と、言語に依存しないUnicode編集APIの検討資料として
残す。Scheme採用を再び保留するための前提条件にはしない。学習用の制作言語の比較と、
Scheme処理系の選定・互換性・実機統合の検証は引き続き別の課題である。

Luaもエディタ拡張の有力候補になる。Emacs的な操作、コマンド、keymap、minibuffer、hook、選択範囲の評価を提供するために、拡張言語をLisp系へ限定する必要はない。[NeovimのLua API](https://neovim.io/doc/user/lua/)は、editor coreと拡張言語を接続する実例になる。

Schemeは、手元で関数やmacroを定義し、エディタを育てる体験に向く。利用者にはMeOS向けSchemeとBASICを作った経験もある。一方、制作側にLuaを選ぶなら、エディタ拡張にもLuaを使うことで、言語、binding、処理系のコードを共通化しやすい。作品の実行stateとエディタの拡張stateは分離する。

初期検討ではUnicode対応だけを理由に拡張言語を固定せず、共通の編集APIとScheme/Luaの比較を先行させる案だった。現在はScheme採用を確定し、言語に依存しない編集APIをその接続先とする。子どもの作品向け言語の選択は[別の比較](learning-languages.md)として扱う。

標準の学習言語をPythonに寄せる利点と、エディタの常駐拡張言語の適性は別に評価する。nihosでは、学習用MicroPythonの検討と、エディタ拡張用Schemeの採用を分ける。Pythonで作品を書くためにSchemeの学習は必要としない。

## Pythonによる拡張との違い

Pythonを使うエディタの実例には[Sublime Textのplugin API](https://www.sublimetext.com/docs/api_reference.html)があり、[VimにもPython interface](https://vimhelp.org/if_pyth.txt.html)がある。Pythonがエディタ拡張に使えない、あるいは言語仕様上成立しないとはしない。command、文字列の加工、外部toolとの連携には十分使える。

一方、エディタ全体を対話的に組み替える用途で、Pythonを既定にする根拠を「教科書と同じ言語」に求めるのは弱い。SchemeのS式とmacroはcommandやmodeのための記法を構築しやすく、Luaは複数文の匿名functionとtableでcallbackや設定を表現しやすい。Pythonでも関数やdecoratorで実現できるが、同じ拡張をどう記述するかを比較したい。Pythonのlambdaが単一式という制約は[言語仕様](https://docs.python.org/3/reference/expressions.html#lambda)にあるが、それだけでPythonを不適と断定しない。

Schemeを採っても、buffer-localな状態やcommandの再定義・登録が自動的にEmacsと同じになるわけではない。それらはeditorのAPIと状態管理で設計する。Pythonのmodule再読込みや既存callbackの参照も、同じく再定義時の契約として検証する。

MicroPythonへ一本化しても、PCのCPython用pluginやlibraryがそのまま使えるわけではない。さらにGC、VM/stateの寿命、実行中断とUI復帰を[移植時](https://docs.micropython.org/en/latest/develop/porting.html)に確認する必要がある。これらは処理系の実装・統合上の課題であり、Pythonの構文に不向きな点があるという主張とは分ける。他のVMもGCや中断の検証を免れない。

初期の推奨構成は、nativeのbuffer/layout/undo、Schemeのkeymap/command/hook、MicroPythonの教材・作品・数理実行である。選択範囲をPythonで加工する機能は、snapshotを実行serviceへ渡し、結果を検証してcoreが一つの編集として反映する形で追加できる。共有するのは言語そのものより、Unicode境界、Range、保存、実行結果の表示と資源管理である。

## 何を比較するか

| 観点 | Scheme | Lua |
| --- | --- | --- |
| コマンド、keymap、hook、選択範囲の変換 | closureやprocedureとして自然に表せる | function、table、closureとして自然に表せる |
| 対話的な変更と評価 | REPL、定義、macroを中心に組み立てやすい | REPL、functionの差替え、tableによる設定が使える |
| Lispの構文を扱う拡張 | S式とmacroをそのまま題材にできる | parserと構文データの表現を別途用意する |
| 日常の短い拡張を書く入口 | 利用者の既存経験を活かせる | 制作側もLuaなら同じ言語から入りやすい |
| 単独のUnicode文字列処理 | Unicode対応の処理系なら文字・属性操作が使いやすい | byte文字列と標準utf8 libraryに、追加APIが必要になる |
| 書記素、IME、表示位置、undo | editor coreが共通で担う | editor coreが共通で担う |
| 実装規模と実行時メモリ | 処理系・feature構成・bindingを選んで測る | 処理系・feature構成・bindingを選んで測る |

Schemeなら全実装が同じUnicode機能を持つとはしない。ここでは[Chibi-Scheme](https://synthcode.com/scheme/chibi/)を具体例にする。Luaは標準Lua 5.5を具体例とし、Lua 5.1、LuaJIT、Luauの標準libraryと混同しない。NeovimのLua interfaceは5.1を基準としており、nihosの互換性を意味しない。

## Unicodeで区別する単位

| 表示例 | UTF-8 bytes | コードポイント | 拡張書記素クラスタ |
| --- | ---: | ---: | ---: |
| が U+304C | 3 | 1 | 1 |
| か＋結合濁点 U+304B U+3099 | 6 | 2 | 1 |
| 𠮷 U+20BB7 | 4 | 1 | 1 |
| 👩‍💻 U+1F469 U+200D U+1F4BB | 11 | 3 | 1 |
| 葛＋異体字セレクタ U+845B U+E0100 | 7 | 2 | 1 |

カーソルの通常移動とBackspaceは、原則として拡張書記素クラスタ単位で設計する。コードポイント一個を常に見た目の一文字と呼ぶと、結合濁点やZWJ列を途中で切ってしまう。境界の基準は[UAX 29](https://www.unicode.org/reports/tr29/)に置き、採用するUnicode dataの版を固定する。

描画幅はこれらとも別である。全角・半角の列数、pixel位置、fontのadvance、縦書き、折返しをlayout側で扱う。書記素が一つだからfontに字形がある、あるいは必ず一つのglyphになるという意味ではない。語境界と禁則・改行機会も書記素境界とは別であり、日本語の語単位移動には追加の方針が必要になる。

## Luaで不足する部分と、使える部分

[Lua公式manual](https://www.lua.org/manual/5.5/manual.html#6.6)のutf8 libraryはencodingを扱う。`utf8.len`、`utf8.codes`、`utf8.offset`でコードポイントの数や境界を求められる。一方、`#s`はbyte数で、`string.sub`はbyte位置を使う。任意のbyte位置で切れば、不正なUTF-8を作り得る。

標準utf8 libraryには、書記素分割、正規化、Unicode全体の文字分類やcase foldingは含まれない。`string.find`で日本語の文字列そのものを探すことはできるが、標準patternの文字クラスや一文字一致を、Unicode対応の正規表現や書記素操作として扱わない。

今回、公式archiveのSHA-256を確認したLua 5.5.1をmacOS hostでbuildし、上表の5例について `#s` と `utf8.len(s)` が表のbyte数・コードポイント数になることを確認した。いずれも `string.sub(s,1,1)` で先頭1 byteだけ切り出すと不正UTF-8となった。書記素の分割やnihos上での実行を試験した結果ではない。

したがって、Lua拡張へ単に全文文字列と整数offsetを渡す設計は避けたい。通常の編集は `cursor:move_graphemes(-1)` や `buffer:replace(range, text)` のようなAPI案で表し、Lua側でUTF-8のbyte計算を繰り返す必要をなくす。Luaの `#s` の意味を書き換えるのではなく、editorの操作として提供する。

## Schemeでもeditor coreが必要な部分

ChibiはUTF-8文字列、Unicode属性、case mapping、比較、正規表現等を提供する。文字列を扱う拡張には便利である。ただし[公式説明](https://synthcode.com/scheme/chibi/)では、UTF-8文字列の `string-ref` は構成によってO(n)であり、iteratorやstring cursor、必要ならindex tableを使うことが推奨される。

文字単位の `string-length` や `string-ref` も、結合濁点とZWJ列を一文字として扱うeditorの仕様を自動的には満たさない。全文を文字ごとに繰り返し参照したり、変換のたびにコピーしたりする構成は、小さな端末ではメモリと時間を使う。Schemeからも、editorのbuffer、範囲、文字境界APIを利用したい。

ChibiのmanualはUnicode 13.0への対応を記述している。実際に採用するrelease/sourceのdataを確認し、editor coreと処理系の属性判定の版が異なる場合の扱いを決める。単に「Unicode対応」と記載するだけでは、対応する文字や境界の版はわからない。

## nihosの編集API案

テキストの正本はZig等のnative coreが持つUTF-8 bufferとし、gap bufferやpiece table等の方式は別途測定して選ぶ。全体を処理系のstringとして常駐させず、必要な範囲だけを取り出す。SchemeとLuaのbindingは同じ操作と責任を提供する。

| 責任 | APIや仕様の案 |
| --- | --- |
| 位置の表現 | 通常はopaqueなmarkerとRange。低水準で整数を渡すならByteOffset等の単位を明記する |
| 変更後の位置 | markerの挿入位置での追従方向を定め、古いrevisionの範囲を無条件に再利用しない |
| 文字移動 | 書記素、語、論理行、表示行を別の操作にする |
| 編集 | UTF-8と範囲の検査、undo group、selectionとmarkerの追従をcoreで処理する |
| まとまった拡張処理 | 編集transactionへ変更をまとめ、成功時に一つのundo操作にする |
| 文字列を変換する処理 | 範囲のsnapshotを渡し、戻り値を検証してから置換する。大きな範囲は上限や分割を設ける |
| 検索 | 検索結果をRangeとして返し、表示・置換の境界を一箇所で検査する |
| IME | 未確定のpreeditはoverlayで扱い、確定時に一つの編集として反映する |
| レイアウト | glyph、幅、hit test、禁則、縦横、折返しは共通layoutが担う |

Lua向けのcolon呼出しと、Scheme向けのprocedure呼出しは表記の違いに留める。たとえば一文字戻る操作は、それぞれ `cursor:move_graphemes(-1)` と `(cursor-move-graphemes! cursor -1)` のように同じ境界規則へ接続できる。いずれも提案APIで、現在のnihosに実装済みではない。

## 原文の保持と正規化

読み込んだUTF-8を保存のたびにNFCやNFKCへ自動変換しない。正規化は検索key、比較、明示的な変換commandの用途に分ける。[UAX 15](https://www.unicode.org/reports/tr15/)の形式を区別し、NFKCが文字の区別を変え得ることを考慮する。検索keyを正規化した場合も、元のbuffer上の範囲へ戻す対応が必要になる。

不正UTF-8を黙って置換して保存しない。初期のtext modeでは読み込み・挿入時に検証してエラー位置を示し、Shift_JIS等のimportは明示した変換として扱う。元データの保持やbinary modeは、必要に応じて別の仕様にする。

## OSS部品の候補

[libgrapheme](https://libs.suckless.org/libgrapheme/)はfreestanding C99のUTF-8境界処理libraryで、書記素、語、文、改行機会などの候補になる。[utf8proc](https://juliastrings.github.io/utf8proc/)は正規化、case folding、属性、書記素処理等の候補になる。採用前に必要な機能を絞り、RV32でのcode/data、tableの配置、実行時間を測る。今回はまだnihosへ組み込んでいない。

二つのlibraryを無条件に全機能でリンクするより、必要な境界処理と正規化の責任を決めたい。Unicode dataはlibraryの採用版に合わせ、同じ版のconformance testを使う。

## 比較検討の観点（選定時の記録）

最初の比較には、日付の挿入、選択範囲の変換、辞書lookup、キー割当、保存時hookを使う。結合濁点、補助面漢字、異体字セレクタ、絵文字ZWJ列を含め、カーソル、削除、undo、IME確定、検索・置換の動作が両bindingで一致することを確認する。

言語のVMだけでなく、実際のbinding込みのcode size、ピークheap、GC、拡張の中断とエラーからの復帰を比較する。作品向けLuaとの共通化が効くならLuaの優先度が上がる。エディタをS式・macroで育てることと利用者の既存経験を重視するならSchemeの優先度が上がる。Unicode編集の正しさは、どちらでも共通coreが担う設計にする。

## `xy` におけるScheme × SQLiteデータモデルとSKKオムニ変換の統合案（2026-10-30追記）

`xy` 専用機（Convivial Machine）としての個性を強め、かつUI・検索・設定・ログの実装を最小の機構へ収束させるため、Schemeのデータモデル、単一owner `sqld`（SQLite）、およびミニバッファ型SKKを次の3点で統合する設計を第一候補とする。

### 1. S式とSQLiteテーブルの双方向マッピングとライブビュー
- SQLiteの基本型（`INTEGER` / `REAL` / `TEXT` / `BLOB` / `NULL`）とSchemeの基本値を1対1に対応させ、任意のS式（設定値、キーマップ、構造化メモ、コード断片）は正規化S式テキスト（またはバイナリ表現）として格納し、検索軸（見出し、タグ、更新時刻、FTS5全文索引）だけをインデックス列へ投影する。
- Scheme側からは生のSQL文字列結合ではなく、上限つきプリペアドステートメント（`sqld` RPC）へ変換される宣言的なS式クエリ `(q table #:where ... #:limit ...)` を通じて連想リスト/ベクタのストリームを受け取る。
- `xy` のバッファは単なるフラットファイルの展開だけでなく、S式クエリ結果のビューとして開けるようにし、編集後の保存を `sqld` のトランザクション（operation receiptつき）へ接続する。

### 2. OS設定管理（世代つきConfig）と自己観測ログ（Hot/Cold 2階層）の統合
- **設定管理 (`sys_config`)**: 画面輝度、フォント寸法、キーマップ、SKK規則、タスク上限等をSQLiteのトランザクションとLFS世代管理の下に置き、Schemeから参照・変更・過去世代へのロールバックを行えるようにする。ただしブート自立性を守るため、SD未挿入やDB未マウント時にも起動できる最小デフォルト設定をROM/SRAMの定数として保持し、`sqld` マウント後に検証済み設定を上書き適用する。
- **ログ・メトリクス管理 (`sys/live-ring` と `sys_events`)**: IRQやカーネル内部、`sqld` 自身からの同期I/OによるデッドロックやSD書込みストームを防ぐため、リアルタイムのイベント（PMP fault、I/O遅延、フレーム時間、メモリ消費）はアロケーション・I/Oなしの固定長リングバッファ（Hot層）へ記録する。Schemeからはこのリングバッファと、アイドル時や明示スナップショット時に `sqld` へバッチ保存された永続証跡テーブル（Cold層）の双方を同じS式クエリで検索・集計できるようにする。

### 3. ミニバッファ型SKKによる「プレフィックス・オムニ変換」
IMEの候補選択UI、ファイラ、辞書検索、設定参照、コマンドパレットを別々のUI部品として重複実装せず、「`▽`（preedit overlay）の入力文字列をディスパッチし、ミニバッファに候補ストリームを出して確定値をバッファへ挿入する」単一の仕組みに統合する。

| 入力パターン | 接続先データ源 | 振る舞い |
| --- | --- | --- |
| `▽かんじ` → `SPC` | `skk_user` + `skk_dict` | 通常のカナ漢字変換。他テーブルの候補を混ぜず日常入力の予測可能性と速度を守る |
| `▽?word` → `SPC` | `jmdict` / `kanjidic` | 辞書引き・英訳・漢字属性の参照と挿入 |
| `▽@keyword` → `SPC` | `books` / `notes` (FTS5) | 書籍や過去ノートの全文検索、引用文や参照リンク `(ref ...)` のその場挿入 |
| `▽:key` → `SPC` | `sys_config` / `sys/live-ring` | OS・エディタ設定値やリアルタイムメトリクスの参照・挿入・変更 |
| `▽(expr ...)` → `SPC` | Scheme評価器（U-mode PMP） | SKKプログラム変換。S式を評価した結果を文字列として挿入 |

さらに `(ime/register-prefix! prefix handler)` のような小さな拡張口を用意し、利用者自身が新しいSQLiteテーブルやScheme関数を変換ソースとして追加できるようにする。


## 2026-10-31: native xyの限定Scheme接続

`scheme_runtime.zig` に定義・字句スコープclosure・GC・明示的な実行量制限を持つ
整数Schemeサブセットを実装し、ミニバッファ、共通Document、読み取り専用システム
バッファ、コマンド登録へ接続した。コード・VM状態は固定の境界内に置き、実機でも
closureとコマンド再登録・エラー復帰を照合した。[実装契約と証跡](../measurements/2026-10-31-xy-scheme-runtime.md)を参照。
R7RS、macro、任意キー割当、利用者操作による実行中断、SQL・保存・U-mode隔離は
未実装であり、既存host向け `scheme_bridge.zig` のフォームを全て接続したものではない。


## `xy`の設定形式（2026-10-31確定）

利用者が読む・編集する `xy` の設定、キーバインド、mode定義、起動処理、保存するUI状態は
S式を正本とする。これらのためにJSON設定ファイルやJSONとの二重管理は新設しない。
macOSとTab5で同じ設定仕様とbindingを使えるようにする。
宣言的な設定データは読み取り・スキーマ検証して適用し、利用者が実行する起動Schemeは
実行量制限のある評価器へ明示的に渡す。S式のデータを読むこととコードを実行することは分ける。
将来の永続 `sys_config` も、世代付きS式を正本としてSQLite/LFSへ保存し、検索用の列は
必要な項目から派生させる。設定ファイルの自動ロードと永続保存はまだ未接続である。

イメージ監査、アセットのハッシュ・寸法マニフェスト、CI・テスト証跡のJSONは従来形式を維持する。
`src/graphics/*font.json` や `keypad_atlas.json` は利用者向けの `xy` 設定ではない。
