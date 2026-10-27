# 回収探索の分割と現在世代のmetadata cache

2026-10-27。`codex/store-crash-model`、実装commit `929c32a`。
[payload回収モデル](2026-10-27-store-payload-gc.md)の探索を再開可能なstepへ分割し、現在世代のleafを保持するcacheを追加した。
同じ128回の64 KiB更新を含む試験で、backend read要求は214,335,488 Bから962,560 Bへ99.55%減少した。
3つのcache構成で保存rangeのhashは一致した。実機の転送量・実行速度を測定した結果ではない。

## 探索stepの契約

[checkpoint_model.zig](../../src/storage/checkpoint_model.zig)に次のAPIを追加した。

|API|役割|
|---|---|
|`beginPayloadSearch(pages)`|transaction内で連続領域の探索を開始|
|`beginPayloadSpace()`|空き容量・最大連続長の集計を開始|
|`stepPayloadSearch(budget)`|指定件数まで進めてpending／found／no_space／spaceを返す|
|`putPrepared(key, data)`|完了済みの対応する探索結果だけを使って書く|
|`cancelPayloadSearch()`|途中または完了済みの探索結果を無効にする|

budgetはroot／leaf slotの確認件数と、bitmap上で判定するpayload page数の2軸。
defaultはleaf 8件、payload page 1,024個。後者はbitmapの1,024 bitを判定するという意味で、1,024回の媒体readではない。
leaf budgetの許容範囲は1〜64、bitmap側は1〜4,096とし、0や上限外を拒否する。
空のslotやcache hitもleaf 1件として数え、I/OがなくてもCPU作業を無制限に続けない。
1 leafの仕事には4 KiBのCRC・identity・126 entryの範囲検査・bitmapへのmarkを含む。
default stepのmetadata read要求は最大8 page、32 KiB。device I/Oの所要時間は別であり、wall-clock上限を保証するものではない。

探索はroot番号・leaf番号・window内位置・連続空き長をstore内に保持する。
`pending`の間に通常read／pinned readを挟める。
pin／release／begin／rollback／put／remove／commitが状態を変更すると、途中・完了済みの探索を無効にする。
古い結果を`putPrepared`へ渡しても、暗黙の追加探索で書込みを始めない。
入力dataへのpointerを保持せず、途中でcancelしても入力bufferをpinし続けない。

既存の`put`と`payloadSpace`は、stepを最後まで回すblocking互換APIとして残した。
native serviceではbegin／stepを使い、pendingの間にschedulerへ処理を返す必要がある。
ホストprobeも反復更新でこのAPIを使うが、pending中に実際のnative schedulerへyieldした検証ではない。
`putPrepared`が行うpayload書込みと、commitのsyncはまだ同期処理。streaming／部分書込みや全I/O経路の実時間上限は未実装。

## cacheの対象と保護

`leaf_cache_pages`は0／64／128を比較した。モデルの既定は0、今回の性能probeの既定は128。
cacheは論理leaf番号ごとの固定slotで、現在世代のleafを保持する。64構成は先頭64枚を保持し、adaptive LRUではない。
古いreader／retained／stagedの別versionは現在世代のcacheを追い出さず、必要ならbackendから読む。
参照先pageとchecksumが一致すれば共有できるため、同じ現在世代を参照する複数rootでmetadataを再readしない。

cache hitでもbufferをCRC・leaf番号・世代・各entryのroot範囲に照らして検査する。
物理pageを再利用する前に、同じpageを持つcache tagを無効にする。
I/O／整合性faultは進行中探索を無効にし、そのinstanceでの書込みを止める。

cacheは検証済みimmutable metadataのviewであり、hit時にbackendの再読取りはしない。
backendを再検査する必要がある場合は`dropMetadataCache()`を使う。
cacheに保持した値のRAM破損を検出する試験と、cacheを捨てた後にbackend I/O faultが表れる試験を通した。
single-ownerで直列に呼ぶ前提は変えておらず、public capability ABIやCPU間の同時read/write lockを追加したものではない。

## RAMとread要求量の比較

[比較tool](../../tools/compare_store_search.py)は、独立した3構成のprocess receiptを比較する。
3構成それぞれで10ケース・23 processが通り、世代3／5／15／277のmetadata・payload全rangeのhashが一致した。

|cache data|cache tag|arm64 store状態|churnのbackend read要求|cacheなし比の削減|
|---|---:|---:|---:|---:|
|0|0|18,800 B|214,335,488 B|—|
|256 KiB（64枚）|1 KiB|281,968 B|107,393,024 B|49.89%|
|512 KiB（128枚）|2 KiB|545,136 B|962,560 B|99.55%|

read要求には初期更新、2 readerの照合、128回の64 KiB更新など、`churn-payload`全体を含む。
128枚構成の最後の探索windowで、実backendから読むleafは384回から1回になった。
rootごとのCRC再計算・entry検査は残るので、read要求削減率とCPU時間削減率は同じではない。
cacheが使える現在世代のleaf数と配置で効果が変わり、小さなworkloadでも常に512 KiBが必要という結果ではない。

RV32 compile上の状態はcacheなし18,792 B、128枚構成545,128 B。
増分526,336 Bは512 KiBのdataと2 KiBのtagで、1 GiB型と16 GiB型は同じサイズだった。
探索cursor・counterによるcacheなし状態の増分は152 B。
基本モデルの32 KiB gateを維持し、cache込みの性能probeには640 KiBの上限を別途設けた。

512 KiBのcache dataは計画中のstore map-cache枠に対応する。tagと基本状態も全体の2 MiB envelope内で別に数える必要がある。
nativeへ組み込む場合はPSRAMへの配置と所有者quotaを確認する段階が残る。
call stack・backend・OS file cacheは上記の状態サイズに含まず、実機の総RAM peakやSRAM余裕を測定したものではない。
native memory profileや保持済み実機候補は変更していない。

## 正しさと作業上限の検査

[追加Zig test 7件](../../src/storage/search_cache_test.zig)で、leaf 1件・payload page 1個のstepを繰り返した。
各stepのmetadata read要求は最大4 KiBで、途中にpinned readを挟んでも11回で同じ割当て位置を得た。
複数windowの集計はblocking版と一致し、完了済み結果を使うputが探索を再実行しないことも確認した。
writer／readerの状態変更による無効化、取消し、異なるfootprintの拒否、cache hit、RAM破損、page再利用を検査した。

payload回収の故障モデルは1枚cacheを有効にして再実行した。
回収と再利用を含む3,024中断条件と正常ack 6件で、最後にackした世代以上の完全なdataだけを回復した。
既存のindex回収3,024条件、checkpoint 5,832条件、初期COW 4,212条件も両build modeで通った。

[新しいnegative control](../../tools/search_negative_control.py)では、作業上限の分岐を外すとstep予算の検査に失敗し、
leafのCRC検査を外すと破損cacheが拒否されず、期待する整合性検査に失敗した。
payload／indexのreader・retained保護を外す4件と、公開前syncを外す既存のnegative controlも反例を検出した。
意図した失敗が単なるcompile errorではないことをrunnerで確認し、diffとログを保存した。

Zig Debug／ReleaseSafe各237件、Python 168件、format／ZLint／ShellCheck、RV32 broker・基本／cache構成のcheckpoint compile、
6種類の既存native ELF link／配置監査が合格した。
3構成の合計69 process試験はhost fileであり、物理電源断、実SDの転送時間、実機のscheduler干渉を検証していない。
disk形式はversion 3のままで、cacheやcursorを媒体へ保存していない。

## 再現と次のgate

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
NIHOS_STORE_LEAF_CACHE_PAGES=0 sh tools/run-checkpoint-test.sh
NIHOS_STORE_LEAF_CACHE_PAGES=64 sh tools/run-checkpoint-test.sh
NIHOS_STORE_LEAF_CACHE_PAGES=128 sh tools/run-checkpoint-test.sh
python3 tools/compare_store_search.py PLAIN_RESULTS_JSON CACHED_RESULTS_JSON
python3 tools/search_negative_control.py .tools/zig-0.17.0/zig
sh tools/run-static-analysis.sh
```

各process試験はprofileごとの新しいdirectoryへbinary・range・結果を保存する。
[構造化結果](2026-10-27-store-search-cache.json)と
[source・binary・range・失敗比較・ログのarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-search-cache-host)を保存した。
manifestを除く96 fileのSHA-256と、保持中のcold-Flash候補55 fileのhashを再照合した。
次はstreaming／部分書込みとtask取消しを扱う段階へ進む。
native serviceでのyield／PSRAM配置、cache込みの遅延測定、移動型cleaner、実SD書込み・除去・実電源断、SQLite永続VFSは残る。
