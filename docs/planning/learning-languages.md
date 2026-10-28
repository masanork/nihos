# 子どもの制作と数理学習に使う処理系の比較

2026年10月25日。言語・学習環境の選定案で、nihosへの移植結果ではない。

MeOSでは利用者自身がSchemeとBASICを端末内開発向けに提供している。nihosでの検討はその再実装だけを目的にせず、子どもが自分の作品を作り、学習にも使いたくなる環境を探す。エディタの拡張言語は[SchemeとLuaをUnicode境界も含めて比較](editor-extension-language.md)し、子ども向けの正面の言語とは分けて考える。

標準の学習言語はPythonを軸とし、端末上の処理系は制作APIを備えたMicroPythonと、数理・データ学習向けのulabを第一候補にする。ゲーム、絵、音を作る体験を強くする対抗案としてLua/Luauを比較する。JavaScriptはWebへの接続を重視する場合の候補になる。どれが子どもの関心を引くかは設計上の仮説であり、実際に触ってもらって確かめる。

## 教科書からPCとAIの学習へつなぐ

Pythonを選ぶ理由に、端末の中だけで学習が終わらないことを加える。[数研出版の情報Ⅰ教科書](https://www.chart.co.jp/kyokasho/26kou/joho/kou/)はPythonとExcel VBAを扱い、[実教出版の教材一覧](https://www.jikkyo.co.jp/highschool/jouhou/jou-text/)にもPythonの入門・演習教材がある。これらの事例から教科書全体の採択割合までは断定しないが、既存教材へ接続する具体的な入口がある。

nihosではPythonの基本構文、関数、list/dict、数値と文字列、標準的な入出力から始め、端末で書いた `.py` とUTF-8/CSVデータをPCのCPythonへ持ち出せる構成を目指す。その後、PC上のデータ分析やAI用libraryを学ぶ際にも、言語の基礎を持ち越せる。

[MicroPythonとCPythonの差分](https://docs.micropython.org/en/latest/genrst/index.html)を前提に、教材向けの対応範囲と検証用の小例を用意する。端末固有の描画・入力は専用moduleへ分け、PC用adapterを設ける案にする。ulabはNumPy/SciPyの全機能を提供せず、PC用のAI packageをそのまま端末で実行できるという約束にはしない。

学習言語のPython採用を、エディタの常駐拡張言語の統一まで広げない。学習者はPythonだけで作品を書いて実行でき、エディタ自体を拡張する人向けにはSchemeを第一候補、Luaを対抗案として比較する。Pythonから選択範囲を加工する等のcommandは、学習用の実行serviceを呼ぶ機能として提供できる。二つの処理系のcode/heapと、実行中断、GC、editorの応答性は測定する。

## 言語と最初の作品

| 候補 | 最初に作るものの案 | nihosで評価する理由 | 残る仕事 |
| --- | --- | --- | --- |
| Lua | touchで動くキャラクター、迷路、音の鳴る絵本 | 小さな組込みVM、単純な制作APIと組み合わせやすい | エディタ、描画・音・入力、保存、実行中断を接続する |
| Luau | 同じ制作課題、型つきの少し大きな作品 | Roblox Studioで使われる言語へつながる。型の説明を後から足せる | C++のVM・compilerを移植し、typecheckerとJITは別に評価する |
| MicroPython＋ulab | タートル、アニメーション、サイコロ実験、グラフ | 一つの言語で作品と計算・配列処理へ進める | 表示・音・入力API、数値構成、GC、中断、独自OSへのembed |
| JavaScript＋QuickJS | 動く絵、音、短いゲーム、将来のWeb作品 | 現代のJavaScriptの学習へつながる | DOMやCanvasは別実装。browser/NodeのAPIをそのまま使えない |
| JavaScript＋MicroQuickJS | 同種の小さな制作、端末機能の拡張 | 固定bufferでVMメモリを管理でき、組込み向き | ES5に近いsubset。現代のWeb教材との互換性を確認する |
| R | 集計、統計、グラフ、データを使う自由研究 | 本物のRを使うなら教材・関数の資産がある | OS、compiler・library、メモリ、graphics deviceまで含む大きな移植 |
| ブロック型の環境 | touchで動く絵、音、簡単な実験 | 文字入力の負担を下げる | 子どもが編集するUIそのものをTab5へ載せる必要がある |

Lua、Luau、MicroPython、ulab、QuickJS、MicroQuickJSの候補はいずれも公開されたOSSを持つ。実際の組込み時は、選んだ版と依存ファイルのライセンスを固定する。

## 子どもが変えたくなる制作環境

処理系だけをREPLとして置くと、最初に何を書くかを利用者へ委ねることになる。nihosでは次の一連の操作まで用意したい。

1. 保存済みの作品を開き、すぐ動かす。
2. キャラクターの色や速さ、台詞、音を変える。
3. 自分で描いた絵や作った音を作品に使う。
4. 失敗した行へ戻り、直して再実行する。
5. ソース・素材・必要なAPIの版を一つの作品として保存し、渡せるようにする。

言語の比較には同じ四つの課題を使う。touch追従のキャラクター、音を並べる短い曲、タートルの模様、サイコロの頻度を表すグラフである。起動時間とピークRAMに加え、最初の変更までに説明した項目、エラーから戻れるか、作品を保存してもう一度開けるかを観察する。対象年齢はまだ固定していない。

## LuaとLuau

[Lua](https://www.lua.org/)はISO Cで実装され、[MITライセンス](https://www.lua.org/license.html)で配布される。2026年10月25日に確認した公式の現行releaseは[5.5.1](https://www.lua.org/download.html)。nihos向けにはallocator、標準I/O、file service、実行中断、表示・入力・音へのbindingを用意する。Lua本体に制作画面やゲーム素材の編集機能が含まれるわけではない。

[TIC-80](https://tic80.com/)は、コード、sprite、map、音、音楽の編集を一体にしたOSSの参考になる。[リポジトリ](https://github.com/nesbox/TIC-80)にはLua、JavaScript、Pythonなどの対応があり、言語と作品形式を分ける参考にもなる。TIC-80全体を移植する案と、nihos向けの小さな制作APIを作る案を比較する。前者でも、表示・音・入力・保存・editorの日本語対応は別途必要である。

[Luau](https://luau.org/getting-started/)はLua 5.1由来でRoblox Studioにも統合されている。[MITライセンス](https://github.com/luau-lang/luau/blob/master/LICENSE.txt)の独立した処理系として使えるが、Robloxの3D環境やAPIが付くわけではない。Lua 5.5と完全互換でもない。[公式説明](https://luau.org/)によるJITの対象はx64/arm64なので、ESP32-P4ではportable interpreterを基準に考える。利用者がRobloxへ関心を持っているなら、言語の接続先として比較する価値がある。

## MicroPythonを標準候補にする理由

絵と音の制作から、数学、CSVの数値、学習記録の集計へ同じPythonで進める。関心の入口を一つに限定せずに済む。タートルやspriteを動かすAPIはnihos側で提供し、Python標準libraryに存在するようには説明しない。

MicroPythonには[ESP32-P4の公式配布](https://micropython.org/download/ESP32_GENERIC_P4/)があり、revision 0.x/1.xと3.x以降でvariantが分かれている。これはハードウェア上でMicroPythonを動かす先例であり、nihosへそのfirmwareを載せるだけで共存するという意味ではない。

nihos向けには[embed port](https://github.com/micropython/micropython/tree/master/ports/embed)を候補にする。C/Hを外部プロジェクトへ組み込むためのportで、独自OSのGC root、stack、allocator、時間、I/O、例外と中断を接続する。ESP-IDF/FreeRTOS向けのportと区別して設計する。

[ulab](https://github.com/v923z/micropython-ulab)はC実装のNumPyに似た配列libraryで、ハードウェアに依存しないuser moduleである。[公式の機能一覧](https://micropython-ulab.readthedocs.io/en/latest/)には平均、標準偏差、polyfit、FFT、線形代数などがある。NumPy/SciPy全体やpandas互換ではなく、含める機能はbuild構成で選ぶ。CPython用のwheelや任意のPython packageをそのまま使えるとはしない。

科学計算では、32-bit floatと64-bit doubleの選択、DEG/RAD、表示桁数、計算履歴、複素数、配列容量も仕様になる。P4の浮動小数点機能だけから、double演算が同じ速度になるとは判断しない。小さな配列から始め、GC、コピー、配列演算中の中断も測る。

## JavaScriptの処理系を選ぶときの違い

[QuickJS](https://bellard.org/quickjs/)は現代のECMAScriptへの対応が広い。子どもがPCやWebの教材へ進むことを重視する場合に有力である。エンジンだけではDOM、Canvas、p5.jsの実行環境にはならないので、nihosの描画APIと、browserで同じ作品を試すadapterを分けて設計する。

[MicroQuickJS](https://github.com/bellard/mquickjs)は、VMが使うmemory bufferを呼出し側から渡す構成を持ち、ROM/RAMを小さくできる。公式のARM Thumb-2向けサイズはP4のサイズ実績ではない。大きさだけを理由に教育向けの標準へ選ばず、言語機能と教材の一致も確認する。

今回、upstream commit `6d4d7eb6b99011d5aab6e88a9b99e8fd4d86c6e9` をmacOS hostでbuildした。VMのmemory limitを32 KiBに指定し、配列の平均と三角関数の点列を計算できた。同じ版では `let x = 1` がSyntaxErrorになり、通常の現代JavaScriptの教材をそのまま使えるわけではないことも確認した。host CLIのVM枠に関する結果で、nihos上の動作や全processの32 KiB動作を証明しない。

したがってJSを採るなら、教育向けの標準候補はQuickJS、MicroQuickJSは省容量の対抗案として扱いたい。APIを小さくしても、言語仕様を変える場合には学習上の違いを明示する。

## Rの代わりに何を提供するか

Rを電卓として使う発想には、入力を残せる、数列をまとめて計算する、統計と図をつなぐという価値がある。この使い方を小さな数理ノートとして取り入れたい。

ただしGNU R本体は、nihosの最初の処理系としては移植範囲が大きい。[公式のbuild説明](https://cran.r-project.org/doc/manuals/r-release/R-admin.html)にはCとFortranのtoolchain等の前提があり、標準library、メモリ管理、OS機能、graphics deviceまで扱う必要がある。[RのMemory説明](https://stat.ethz.ch/R-manual/R-devel/library/base/html/Memory.html)にある初期GC thresholdを、そのまま必須常駐RAMや最小RAMと解釈しない。32 MiB上での不可能性を今回証明したわけではないが、既存の軽い組込み処理系を使う計画より研究負担は大きい。

当初はMicroPython＋ulabに、入力履歴、表、グラフ、CSV、SQLiteからの範囲指定データ取得を付ける。電卓の画面から平均、ばらつき、回帰、ヒストグラム、関数グラフへ進めるようにする。表示・CSV・SQLとの接続はこれから実装する機能であり、ulabに全て含まれるわけではない。R風の利用体験として位置づけ、RやCRAN packageと互換と呼ばない。

記号式の因数分解・微積分が必要なら、統計とは別にCASを評価する。R、NumPy風の配列計算、CASでは学ぶ内容と実装費用が異なる。

## 小さい子どもとtouch中心の入力

文字入力をまだ負担に感じる層には、ブロックや命令カードの入口を用意する案がある。[MicroBlocks](https://microblocks.fun/)の、ブロックを押すとすぐ実行され、値を観察できる仕組みは参考になる。標準の編集画面をTab5へ移植できたという実績はない。

[Blockly](https://docs.blockly.com/guides/get-started/what-is-blockly/)はWebのeditor libraryである。QuickJSを組み込むだけで動くものではない。初期はPC側でのブロック編集か、Tab5向けに命令の種類を絞ったnative UIを比較する。端末だけで編集することを優先するなら、editorの表示・touch操作も実装の範囲に含める。

## 比較してから決める

最初の比較はMicroPython＋ulabとLua/Luauに絞り、同じ制作課題と数理課題を動かしたい。Scriptを端末でcompile・実行できるので、セルフ開発の入口にWasm出力を必須としない。処理系のbytecodeとWasmは別の形式で、各々の利点が出る段階で配布形式を決める。

処理系のheap上限、無限ループの中断、GCや配列関数中の停止、API呼出し中の待機、保存した作品の再読込みを共通の試験にする。作品を変えたくなるかは、言語名やbenchmarkから推定し切れない。子どもが変更して保存する過程を観察して、標準言語と教材の深さを決める。
