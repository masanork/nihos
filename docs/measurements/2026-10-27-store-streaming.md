# 固定bufferのstreamingと部分更新・取消し

2026-10-27。`codex/store-crash-model`、実装commit `0bd8315`。
[分割探索／metadata cache](2026-10-27-store-search-cache.md)に、全objectをRAMへ載せない書込みAPIを追加した。
16 GiB疎fileへ33 MiB＋17 Bのobjectを4 KiBの入力bufferで書き、別processで全byteとCRCを照合した。
部分更新もstepに分けたが、現在の連続extent形式ではobject全体をCOWでコピーする。
SQLite向けの低増幅なランダムwriteを完成させたものではない。

## 書込みと公開の境界

[checkpoint_model.zig](../../src/storage/checkpoint_model.zig)に以下を追加した。

|API|役割|
|---|---|
|`beginStream(key, length)`|全長を宣言して連続領域を確保。割当て探索はblocking|
|`beginStreamPrepared(key, length)`|分割探索の完了済み結果だけを使用|
|`writeStream(handle, bytes)`|1 data pageの残りまでcopyし、消費byte数を返す|
|`finishStream(handle)`|全長を受け取った場合だけstaged leafを更新|
|`abortStream(handle)`|この未完了操作を捨て、先行するstaged変更は保持|

公開は従来どおりtransactionの`commit`で行う。finishは耐久化のackではない。
data／sidecar／leafのsync → root書込み → rootのsync → ackという順序を保つ。
未完了のstreamがある間はcommit、別のwriter、remove、回収探索を`Busy`で拒否する。
現在世代／pinされた旧世代のreadとreader解放は可能である。

writerはprivateな4 KiB data bufferと4 KiB checksum-table bufferを持つ。
間にreadがself.cacheを使っても、分割途中のdataやsidecarを壊さない。
入力pointerを保存せず、消費した分をcopyした後に返す。
1回のwriteは最大4 KiBを受け取り、最大2 page、8 KiBのbackend writeを行う。syncは行わない。
4 KiB以外のchunkや最終pageの0埋め、複数checksum tableを扱う。

宣言長を超える入力を拒否し、不足したfinishは`IncompleteStream`のまま追加入力を待てる。
0 B objectも明示的にfinishする。
handleはinstance内のtokenで、取消し・slot再利用後の古いhandleを拒否する。
`rollback()`は進行中streamも解除し、transaction全体を捨てる。
I/O／整合性faultでもwriterとtransactionを解除し、後続書込みを拒否する。
callerのtask ownerとの接続やpublic capability ABIは追加していない。

## 固定長の部分更新

`beginPatch(key, offset, length)`と`beginPatchPrepared`は、既存object内の同じ長さの範囲を置き換える。
範囲外への伸長・truncate・sparse holeの作成はこのAPIでは行わない。
sourceはstaged rootから取るため、同じtransaction内の先行put／patchを次のpatchへ反映できる。

`stepPatch(handle, replacement)`は、sourceのprefix／suffixを1 page以内ずつ検証してコピーするか、replacementの一部を受け取る。
返り値は入力消費数、完了、入力待ちを区別する。
prefix／suffixの処理中は入力消費が0でも進捗があり、入力待ちの場合はI/Oをしない。
1 stepのsource read要求は最大8 KiB、write要求は最大8 KiB。callerはstep間で処理を返せる。
最後は`finishStream`、その後にtransactionのcommitが必要となる。

現在の形式は1 objectにつき連続したdata＋sidecarを参照するため、短いpatchでも全objectを書き直す。
今回の20 B patchもdata／sidecarで34,643,968 B、leaf／rootを含め34,652,160 Bを書いた。
メモリを固定量にした成果と、write増幅の改善は別である。
大きなSQLite DBへの4 KiB更新を接続する前に、変更extentだけを差し替え、未変更rangeを共有するpaged mapが必要となる。

## メモリ

|構成|arm64のstore状態|RV32 compileのstore状態|
|---|---:|---:|
|metadata cacheなし|27,120 B|27,104 B|
|512 KiB data cache＋2 KiB tag|553,456 B|553,440 B|

前回比の増分はarm64で8,320 B、RV32で8,312 B。private buffer 8 KiBとwriterのscalar状態による。
基本状態は32 KiB gate、cache込みは640 KiB gateに収まる。
callerの4 KiB入力buffer、patch時の一時buffer、call stack、backend、OS file cacheは上記に含まない。
store自身はheapを確保せず、object長によってwriter bufferを増やさない。
2 MiB store envelopeとnative memory profileは変更しておらず、PSRAM配置と実機の総RAM peakは未測定。

4 GiB＋17 Bを宣言し、1 Bだけ受け取って取消す型・進捗テストも通した。
これはu64長を保持する確認で、その長さのdataを実際に転送・耐久化した試験ではない。

## ホスト試験

[追加Zig test 8件](../../src/storage/stream_test.zig)で、分割入力、readとの交互実行、未完了commit拒否、
finish前後のrollback、先行staged変更を保つabort、stale handle、prepared割当て、長さ境界、空object、
部分更新のprefix／suffix・先行patch保持、入力待ちと取消しを検査した。

streamとpatchそれぞれで82個の書込み／sync event、3種の背景writeback、2種のflush順、6種のsector prefixを中断した。
各2,952条件、計5,904条件で、旧または完全な新世代だけを回復した。
正常ackは各6件で必ず新世代を回復した。I/O fault後はwriter tokenも解除されていた。
小さいobjectの有限な故障モデルであり、全object長・全媒体故障や実電源断の証明ではない。

[新しいnegative control](../../tools/stream_negative_control.py)は、長さ不足のfinish拒否を外すと未完了操作を受理して試験に失敗し、
rollback時のwriter解除を外すと次のwriterが`Busy`のままになって失敗した。
cache・探索予算・payload／indexのreaderとretained保護・公開前syncの既存negative control 7件も反例を検出した。

[実file runner](../../tools/stream_probe.py)は16 GiB fileをexclusive createし、先頭rootと親directoryをsyncしてからprobeを起動する。
payloadは末尾128 MiBの領域を使い、末尾64 KiBはreserveとして維持した。
4 KiBの入力bufferから34,603,025 Bを生成し、8,449 data pageと9 checksum pageを書いた。
別processから全byteとobject CRCを検査した。

|ケース|結果|
|---|---|
|33 MiB＋17 Bの生成と再open|入力bufferを拡大せず全byte一致|
|1 MiB＋17 Bでabort／rollback|旧世代2を維持|
|同じ途中位置でSIGKILL|旧世代2を回復|
|全dataのfinish後、commit前のSIGKILL|旧世代2を回復|
|checksum表境界をまたぐ20 B patch、ack後のSIGKILL|新世代3と前後の全byteを回復|
|保存rangeから別の疎fileを再構築|patched objectとCRCが一致|

6ケース・12 process、うち3つの所有childをSIGKILLした。
SIGKILLはOS cacheを失わせないため、物理電源断試験とは区別する。
archiveは媒体全体をcopyせず、metadata 1,056,768 Bと両世代分のpayload／sidecar 69,287,936 Bのrangeを保存する。
runnerの保存・復元も64 KiBずつ処理し、未使用範囲は0のholeとする。

Zig Debug／ReleaseSafe各245件、Python 168件、format／ZLint／ShellCheck、RV32のstream／patch入口を含むcompile、
6種類の既存native ELF link／配置監査が合格した。
従来のcacheありcheckpoint実file試験10ケース・23 processも再実行して通した。
既存の回収・公開中断モデルも両build modeで通り、native起動経路と保持済みcold-Flash候補は変更していない。

## 再現と次のgate

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
sh tools/run-stream-test.sh
python3 tools/stream_negative_control.py .tools/zig-0.17.0/zig
sh tools/run-checkpoint-test.sh
sh tools/run-static-analysis.sh
```

[構造化結果](2026-10-27-store-streaming.json)と
[source・binary・range・失敗比較・ログのarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-streaming-host)を保存した。
manifestを除く87 fileのSHA-256と、保持中のcold-Flash候補55 fileのhashを再照合した。
次は部分更新で未変更rangeを共有するextent mapと、その参照を守るGCを検討する。
native serviceのowner／取消しとの接続、PSRAM配置、実SD書込み・除去・電源断、SQLite PERSIST/FULL・WALは残る。
