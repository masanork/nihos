# xy: GPUI共通描画、アニメーション、R7RS-smallへの段階

## 今回の実装

`apps/xy-gpui`は実際のGPUIウィンドウを作り、共通Zigのxy描画とグラフを並べる。
既存CocoaホストのSQLite/source編集機能を置き換えたという意味ではない。
GPUIはイベント・フォーカス・レイアウト・画像転送、共通コアは文字・組版・画素を担当する。

```mermaid
flowchart TD
    Input["時刻・キー押下/解放・フォーカス"] --> Model["共通アプリ更新モデル"]
    Model --> Plot["共通Canvasのグラフ"]
    Editor["共通xy Document"] --> Text["共通組版・TrueType"]
    Text --> RGB["完成RGB565フレーム"]
    Plot --> RGB
    RGB --> BGRA["BGRA展開"]
    BGRA --> GPUI["GPUIの画像ペイン"]
    RGB -. "次段階で接続" .-> Native["Tab5の表示所有者"]
```

`src/app/animation.zig`は単調時刻を呼出側から受け、16,667usの固定刻みで更新する。
1回の追いつき処理は4stepまでで、超過時間は計測して捨てる。pause中と時計巻戻り時は
再基準化し、再開時に過去の時間を一括実行しない。押し続けによる再トグルを抑制し、
フォーカスを失うとheld状態を解放して停止する。

グラフは固定小数点のsine tableを使い、native整数ABIに浮動小数点状態を要求しない。
軸・文字の背景は再利用する。共有RGB565→BGRA変換の後だけGPUIへ渡し、
画像の保持・atlas退役もホストが管理する。停止中の定期再描画は要求しない。

SDLは将来のbackend/互換API候補として残す。今回SDLを追加する理由はなく、既存の
Canvas/SurfaceをGPUI内へ接続して画素の正本を維持する。SDLをMacだけへ導入しても
Tab5との描画エンジン共有にはならない。採用時は両環境の同一描画経路または明示的な
backend差を測定し、互換範囲を定める。

## 次の接続と受入条件

| 順序 | 対応 | 受入条件 |
| --- | --- | --- |
| 1 | GPUI pane・時計・停止/再開・キー | 今回実装。単体/画素比較と実ウィンドウを分けて記録 |
| 2 | versioned app event/frame API | native v1を実装。GPUI接続、32キーのpress/release/held、focus/cancel、呼出側所有frame、サイズ/時間/転送メモリ上限。Wasm linear memoryの検査は次のadapterで実装 |
| 3 | Scheme callbackとplot library | `app/*`・`plot/*`のGPUI接続、GC root、256step予算・64cell予約、失敗時rollback・解除・停止を実装。R7RS library/importと中断後の継続再開は未実装 |
| 4 | WAMR実験の通常サービス接続 | 別worktreeの実験を監査して統合。MeOSのSnake等をadapter経由で起動→入力→終了→xy復帰。trap/中断でも資源回収 |
| 5 | Tab5で同じモデルを描画 | 実候補で入力遅延・frame時間・転送量・PSRAM/SRAM・tearingを測定。host/RV32 linkを実機成功と扱わない |

第2段階のnative契約は[`include/nihos_app.h`](../../include/nihos_app.h)に定義した。
`query → open → event/state/frame → cancel`で1つのforeground sessionを管理する。
キーは32個の論理slotで、plotは0..3を停止/減速/加速/resetに割当て、残りも状態を保持する。
文字入力やIMEはこのキーbitsetへ混在させず、既存editor helperに残す。
イベントのpressed/releasedは最後に受け付けたイベントに対するedgeであり、queueではない。
focus喪失とcancelは追加updateを実行せず、全キーと端数時刻を解放する。
focus復帰だけでは再開せず、cancel後はopen以外で再開しない。

完成frameは呼出側のバッファに同期的に書き、呼出し後に保持するpointerやcallbackはない。
RGB565LE/BGRA8、240..1280×180..720、stride最大8192byte、1要求最大5,898,240byte。
行のpaddingと超過capacityは保存し、成功時だけmetadataを公開する。renderは時刻を進めない。
既存のGPUI画像copyとframe後のatlas退役はhost側に残す。frame generationはpane単位かつ
session内の比較用で、サイズ・format・openをまたぐcache identityではない。
native pointer/size_tを含む関数をWasmから直接呼ぶ設計ではなく、Wasm adapterではoffset、
length、上限、所有とtrap時回収を改めて検査する。

第3段階では同じeditor VMにScheme closureを登録し、更新eventから同期的に呼び出す。
GC rootはcallbackとそのlexical環境まで辿り、登録置換・解除・cancel・再openを検証する。
callbackに渡すticksは固定step数の下位31bit。1eventに最大4stepをまとめてもcallbackは
1回とし、描画からは呼ばない。`app/pause!`は保持、`app/stop!`とCtrl-Cは解除して停止する。
F5/Run/Ctrl-Enterで現RAM bufferを評価する。callbackの失敗は文書・定義・view・plotを戻して
callbackを解除する。同期評価の途中を強制停止する仕組みではなく、callback間の停止と
256評価step・深さ24未満・ヒープの64cell予約による中断である。256cellのGCや文書操作の
時間も含め、実機のwall-clock deadlineを保証する測定はまだない。
この段階の名前空間は独自VMのextensionで、将来の`(nihos app)`/`(nihos graphics)`へ分離する。
標準library、proper tail calls、継続、WASM接続は完了していない。

MeOSの手元ソースは`apps/wasm/{snake,tetris,shooter}.c`と`apps/wasm/meos.h`を参考にした。
時刻・キー・矩形/画像/文字・sleep/presentで動いている。nihosではフレーム公開を
入力pollやsleepの暗黙の副作用へせず、更新・描画・公開を明示して扱う。
ゲームにはrelease/heldが必要だが、現行Tab5 Keyboardの編集用adapterはreleaseを捨てるため、
device側入力との接続には追加実装が必要である。

## R7RS-smallの差分

現行`scheme_runtime.zig`は256 cells、64-byte token、深さ24、1024stepの限定処理系。
closureと要求間GCはあるが、R7RS準拠ではない。app extensionとcallback budgetを追加したが、
標準言語の差分は次表の通り残っている。

| 整備対象 | 実装上の要点 |
| --- | --- |
| proper tail recursion | Zig再帰スタックへの依存を外し、末尾呼出しで評価frameを増やさない |
| 中断/再開とGC | 実行予算をホスト方針として分離。継続中の評価stack・closure・callbackをGC rootとして保持 |
| reader/標準データ | 文字・vector・bytevector・可変長引数・引用記法・数値読取りとUnicode文字列操作 |
| `syntax-rules` / libraries | 衛生的macro、`define-library`・import/export、標準bindingの適合表 |
| control / conditions | 多値、継続、`dynamic-wind`、parameter、例外、portを段階実装 |
| 数値 | 対応範囲を明示。数値塔全体を必須とせず、数理用の実数・三角関数を含む実用構成を測定 |

まず仕様例と既存処理系で差分テストを作り、独自VM改良とChibi等を同じeditor binding込みで
比較する。code/heap、GC停止時間、cancel遅延、既存拡張の互換性を測定してから実行系を決める。
R7RS適合と描画/ゲームAPIの実装完了は別に判定する。

参照: [R7RS-small report](https://small.r7rs.org/attachment/r7rs.pdf)、
[Chibi](https://github.com/ashinn/chibi-scheme)、
[GPUI 0.2.2 RenderImage](https://docs.rs/gpui/0.2.2/gpui/struct.RenderImage.html)、
[SDL software renderer](https://wiki.libsdl.org/SDL3/SDL_CreateSoftwareRenderer)。
