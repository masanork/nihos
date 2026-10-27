# SQLite cache比較と永続VFSのbounded allocator検証

2026-10-28。実装commit `12998a5`、branch `codex/store-crash-model`。
[前回の実SQLite VFS](2026-10-28-sqlite-store-vfs.md)を使い、cache候補とtask-owned allocatorを検証した。
host結果では512 KiB候補を維持できる。native linker配置・実機I/O・全workloadの保証はまだ行っていない。

## 同じDBでのcache比較

SQLite 3.54.1、4 KiB page、PERSIST／FULL、temp_store=MEMORY、single connectionを継続する。
全profileでlookasideを無効にし、host32／host512は`cache_size=-32`／`-512`を設定する。
64行（77,824 B）と640行（667,648 B＝652 KiB）、各行1,000 B blob＋version、別marker tableを使った。
比較前に旧値を検査し、その時点のsnapshotへ条件を揃える。全行とmarkerを1 transactionで新値へ更新した。
各profileの最終DBを抽出したところ、同じ行数の3 profileでSHA-256が一致し、再構築後のSQL照合・integrity_checkも通った。

|DB|profile|write call|backend sync|SQLite malloc high-water|
|---|---|---:|---:|---:|
|76 KiB|host32|444|20|141,456 B|
|76 KiB|host512|411|8|141,456 B|
|76 KiB|bounded＋固定512 KiB cache|411|8|25,528 B|
|652 KiB|host32|4,008|164|141,472 B|
|652 KiB|host512|3,590|12|653,472 B|
|652 KiB|bounded＋固定512 KiB cache|3,590|12|25,552 B|

652 KiB DBではhost512のwrite callが10.43%、syncが92.68%減った。
モデルは4 KiB COW書込みをfile backendへ要求する。数字にはSQLite journal・spillとstore metadataが含まれる。
SD throughput・latency・wearの測定ではない。host32の大きな確保要求にはSQLiteのpage-cache bulk確保も含まれ、
cache_sizeは[目標値](https://www.sqlite.org/pragma.html#pragma_cache_size)であって全malloc量のhard capではない。

## bounded版の割当て

[store_allocator.c](../../probes/sqlite/store_allocator.c)で[SQLiteのmemory methods](https://www.sqlite.org/c3ref/mem_methods.html)を設定した。
専用binaryはSQLITE_ZERO_MALLOCでcompileし、SQLiteのlibc malloc fallbackを持たせない。
このbinaryへhost allocator profileを指定すると実際にNOMEMとなり、正しいbounded profileでは保存・再openできた。

pageはSQLite公式の外部page-cache bufferへ配置する。
512 KiBの領域と、runtimeのSQLITE_CONFIG_PCACHE_HDRSZからcell数を計算する。
今回のarm64ではheader込みcell 4,368 B、120 cell。data相当は480 KiBで、残りはheaderと端数になる。
bounded profileのcache_sizeはこの120 pageに合わせる。nativeではそのbuildのheader寸法で再計算する。

小objectは既存の8〜4,096 B classとtask resource ledgerを使う。
host限定profileのquotaは`[40,16,64,64,64,6,10,16,8,1]`。
要求parent 63,376 B、buddy reservationは64 KiBのまま。
旧profileの8 B classと1 KiB classの不足をtraceで見つけ、64 KiB reservation内で調整した。初回失敗JSONも保存する。

`integrity_check`にはSQLite実装上page sizeの2倍、8 KiBのscratch要求があった。
既存buddyとtask ledgerで、8 KiBまで・同時1本のhost限定経路を追加した。buddy reservationは最大16 KiB。
これを含むparentの最大reservationは80 KiB。parent closeはscratchが残る間拒否する。
foreign task／interior pointer／2本目／上限超えを拒否し、task退役時の回収も検査した。
SQLite経由のreallocも、移動先不足時の旧data保持、slot解放後の移動、再度の同時確保拒否を検査した。
nativeのC allocator ABIと既存native profileは変更していない。

|bounded版で確保する領域|上限|
|---|---:|
|外部SQLite page cache|512 KiB|
|小object用parent|64 KiB|
|大きいscratch用buddy block|16 KiB、同時1本|
|合計|592 KiB|

表のmalloc high-water 25 KiB前後は、外部page cacheとbuddy予約の全量を表していない。
Store／owner／queue 596,640 Bとの既知領域の単純合計は最大1,202,848 B。
host oracleの共有buddy heap自体は4 MiBで、SQLiteのledgerは最大80 KiBを借りて全返却する。
shared heap metadata、C wrapper metadata、stack、client/backend、OS cache、全機能同時peakはこの合計に含まない。
SQLite 2 MiB・store 2 MiBの計画envelopeは維持する。PSRAMの実配置とnative peakは別gateである。

## 永続DBでのOOM検証

小さいDBの通常updateが通る300回のmalloc／realloc呼出しを基準に、各地点で一度だけNULLを注入した。
注入processごとにSQLiteをshutdownし、全block解放・task parent返却・共有heap回復を確認した。
別の正常processで同じ媒体を開き、全64行とmarkerが旧値か完全な新値であること、integrity_check=okを確認した。

300 processはいずれも操作または後続検査でNOMEMとなった。
うち82件はSQL COMMIT自体が成功した後の検査中にOOMとなり、82件とも新値を保持した。
残る218件は旧値を回復した。probe全体の失敗を「COMMITが失敗した」と読み替えていない。
対応する正常verifier 300 processも成功し、全300地点で注入が1回だけ発生した。
この有限workloadの結果で、全queryや大きいDBのあらゆるOOM経路の証明ではない。

6 profile・snapshot再構築・allocator edge／fallback拒否・OOM replayの合計640 processが合格した。
既存PERSIST／hot-journal／sync省略negative controlも20 process・4 SIGKILLで再実行して合格した。
C allocatorの既存probeと新しいscratch probe、Zig Debug／ReleaseSafe各284件、Python 168件、
format／ZLint／ShellCheck、C warning-as-error、C 2 sourceのClang analyzer診断0、既存RV32 compile／6 native ELF監査も合格。
新しいSQLite allocator／VFSをRV32で実行・linkした証拠ではない。

[構造化結果](2026-10-28-sqlite-cache-bounded.json)と
[archive](/Users/masanork/Documents/Codex/2026-10-28/nihos-sqlite-cache-bounded-host)にsource・binary・snapshot・全300 replay・診断を保存した。
保持中の実機候補55 fileのhashは一致し、USB書込みは行っていない。
次は実store allocatorのNoSpaceと追加I/O故障、より広いSQL要求・schemaサイズでこのquotaを検査する。
native配置／stack／DMA／終了通知、実SD書込み・抜去・電源断、汎用VFS統合、WALは未完了である。
