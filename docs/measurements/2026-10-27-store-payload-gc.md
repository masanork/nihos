# payload連続領域の非移動型回収

2026-10-27。`codex/store-crash-model`、実装commit `ce2a8f2`。
[index回収モデル](2026-10-27-store-index-gc.md)へ、参照のないpayloadとchecksum sidecarの領域再利用を追加した。
空でないobjectの反復更新と、16 GiB疎fileの末尾に設けた小領域での64 KiB data更新を通した。
payloadの移動・圧縮は行わず、連続した空きがない場合は書込み前に`NoSpace`を返す。
実SD／NORの書込み、Tab5実行、実電源断、SQLite永続VFSは未検証・未接続のままである。

## 割当てと回収

[checkpoint_model.zig](../../src/storage/checkpoint_model.zig)は、未使用の末尾に収まればその位置へ書く。
末尾はcurrent／retained／staged／readerのすべてのhigh-water markより後ろとし、巻き戻さない。
収まらなければ固定サイズのbitmapを使ってpayload領域を順に調べ、最初の十分な連続空きを選ぶ。

defaultのbitmapは4 KiBで、1回に32,768 page、128 MiBを扱う。
各windowで、両disk root・進行中transaction・2つのreader snapshotのleafを検査し、
参照されたpayloadとsidecarの全pageを使用中としてmarkする。
空きの連続長はwindow間でも引き継ぐ。媒体の全pageを表すRAM配列は持たない。
別rootが同じleafを参照していても、現段階ではその都度metadataを読む。

`collectPayload()`はroot-only checkpointで旧disk rootを退役させる。
index／payloadの新規pageを必要とせず、容量不足時にも実行できる。
pinされた旧世代の領域は引き続き保護し、`release()`後に再利用可能になる。
staged rootにあるすべてのkeyも保護するため、同じtransaction内の先行putを後のputが壊さない。
rollbackした未公開の領域は、以後の割当てで再利用できる。

payload、sidecar、leafのsync → root書込み → rootのsync → ackという順序は変えていない。
復旧はbitmapの保存状態や未公開のdataに依存せず、検証済みのroot参照から再び空きを求める。
mark中のI/Oエラーやleaf破損を空きとみなさず、instanceをfaultにして書込みを止める。

## reserveと形式

`payload_reserve_pages`で末尾の予約領域を通常割当てから除外する。
payloadのsidecarを含め、rootのhigh-water markも予約領域へ入ることを拒否する。
予約量をroot headerへ記録するため、実験用形式をversion 3へ更新した。
異なるreserve geometryや旧version 2のrootを、CRCが有効でも書込みなしで拒否する。
移行・自動format・実機媒体の更新は行っていない。

今回の16 GiB file probeは末尾64 pageのうち4 page、16 KiBを予約し、60 pageを通常領域にした。
小容量の故障モデルでは2 pageのreserveも試した。
defaultの実験用Configはreserve 0であり、最終Tab5 profileの値を確定したものではない。
この回収はdataをcopyしないため、回収自身のpayload作業領域は0 pageで済む。
確保したreserveを借りて移動するcleaner、そのquotaや返却手順はまだ実装していない。

## メモリと探索費用

|項目|今回|前回|
|---|---:|---:|
|arm64のstore状態|18,648 B|14,544 B|
|RV32 compile上のstore状態|18,640 B|14,536 B|
|増分|4,104 B|bitmap 4 KiBと探索counter|
|mount読取り上限|1,056,768 B|同じ|
|通常の1 byte read要求量|12,288 B|同じ|

store自身はheapを確保せず、同じwindow設定なら1 GiB型と16 GiB型の状態サイズは同じ。
descriptorのhost gateを16 KiBから32 KiBへ変更し、追加のbitmapを明示的に予算へ含めた。
状態にはcall stack・backend・OS file cacheを含まない。
2 MiBのstore envelopeやnativeのメモリ割当てを変更したわけではなく、総RAM peakは実機未測定。

`payloadSpace()`は全windowを調べて空きの合計と最大連続長を返す。処理時間を制限したAPIではない。
default geometryの16 GiBでは最大128 windowを調べ、割当て中の保護対象は最大640 leaf参照となる。
最悪の場合のmetadata read要求は`128 × 640 × 4,096 = 335,544,320 B`に達し得る。
bitmapのRAMは固定でも、探索I/OとCPU処理は容量・参照数に応じて増える。

16 GiB probeの`churn-payload`全体では214,335,488 Bのbackend read要求が出た。
これは128 leafを使った状態での初期更新・pin照合・128回の64 KiB更新を含む。
OS cache経由の要求量であり、物理disk／SD転送量や実機latencyではない。
正しさのモデルとしては進んだが、この探索をそのままforegroundのnative VFSへ組み込まない。
window単位で中断・再開する予算、metadata参照の重複排除やcacheが次の性能gateとなる。

## 検証結果

[追加Zig test 9件](../../src/storage/payload_gc_test.zig)で以下を確認した。

- 8 pageの通常領域で17 Bのobjectを512回更新。各世代はpayloadとsidecarで2 pageを使い、回収後は6 page空き。再open後も最後のdataが一致。
- 両disk root・2 readerが容量を埋めた場合の`NoSpace`、書込み前の停止、pin解放後の更新、reserveが未変更であること。
- transaction内の複数keyの保護、容量不足時の既存staged data保護、rollback後の領域再利用。
- 空き14 pageでも最大連続長が10 pageなら12 page要求を拒否し、最後の参照を退役後にwindowをまたぐ12 pageを割当て。
- 回収と再利用を連続させた84 eventについて、3種の背景writeback × 2種のflush順 × 6種のsector prefix。
- 探索中のI/O failure後に書き始めないこと、reader viewと旧disk rootのdata保護、reserve geometry／旧形式拒否。

新しい中断campaignは3,024条件。正常ack後は世代6を回復し、途中では最後にackした世代（4または5）以上の完全なdataだけを許容した。
回収をackした後の再利用が中断した場合、回収前の世代4への巻戻りも拒否する。
これは選んだ故障モデル内の結果であり、実媒体の電源断耐性の証明ではない。

[negative control](../../tools/payload_gc_negative_control.py)でpayloadのreader保護だけを外すと、pinされたdataが`Corrupt`になった。
payloadのretained root保護だけを外した場合も、current root破損後のfallbackで`Corrupt`となった。
indexのreader／retained保護を外す2件と、公開前のsyncを外す既存のnegative controlも引き続き反例を検出した。

実file試験は10ケース・23 process。16 GiB fileの末尾60 pageで、64 KiB objectと既存の4,101 B objectを扱った。
2 readerを保持して連続領域が尽きた際の停止と、解放後の再利用を確認した。
その後128回の64 KiB更新と回収を行い、別processから世代277、両object、空き40 page・最大連続長23 pageを照合した。
4 pageのreserveは前後で同じhashだった。保存したmetadata／payload rangeから別の疎fileへ再構築しても同じ検査に通った。
16 GiB全体を埋めた試験や、ほぼ満杯の実SD workloadではない。

Zig Debug／ReleaseSafe各230件、Python 168件、format／ZLint／ShellCheck、RV32 broker／checkpoint compile、
6種類の既存native ELF link／配置監査が合格した。
index回収の3,024条件、checkpointの5,832条件、初期COWの4,212条件も両build modeで通っている。
native起動経路と保持済みcold-Flash候補は変更していない。

## 再現と保存

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
sh tools/run-checkpoint-test.sh
python3 tools/payload_gc_negative_control.py .tools/zig-0.17.0/zig
python3 tools/index_gc_negative_control.py .tools/zig-0.17.0/zig
python3 tools/checkpoint_negative_control.py .tools/zig-0.17.0/zig
sh tools/run-static-analysis.sh
```

[構造化結果](2026-10-27-store-payload-gc.json)と
[source・binary・range・失敗比較・ログのarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-payload-gc-host)を保存した。
manifestを除く55 fileのSHA-256と、保持中のcold-Flash候補55 fileのhashを再照合した。
次は探索量を制限する仕組みとmetadata cache、その後にstreaming／部分書込みを進める。
移動型cleaner、bounded tail replay、実SD／NORの書込みと除去試験、SQLite PERSIST/FULL・WALは未実装のまま。
