# 実SQLiteのPERSIST journalと実験store VFSのhost検証

2026-10-28。実装commit `1f68223`、branch `codex/store-crash-model`。
[copy-owned service](2026-10-28-store-service.md)を使う限定的なSQLite VFSを追加した。
実際のSQLite 3.54.1でDB作成・保存・再open・rollback・hot journal回復が通った。
host fileによる結果で、native SQLite sessionや別branchの汎用VFSへは組み込んでいない。

## 接続した範囲

[store_vfs.c](../../probes/sqlite/store_vfs.c)は`/main.db`と`/main.db-journal`だけを扱う。
既存store object 1・2を空で準備し、SQLiteのopen/createをその固定slotへ対応させる。
一般的な名前空間・path traversal解決・任意file作成は実装していない。
journalのdeleteは、同slotを0長にしてsyncする論理削除とする。main DBのdeleteは拒否する。
1つのSQLite connection lifetimeだけを許し、2個目のmain DB openは拒否する。
他processとの排他はimage全体のfile backend exclusive lockに依存する。

[store_bridge.zig](../../probes/sqlite/store_bridge.zig)は、C callbackを最大4 KiBのcopy要求へ分割してserviceに送る。
xWriteで伸長が必要なら先にtruncate要求を送り、失敗時にはSQLITE_FULLまたは対応するIOERRを返す。
失敗したwriteが部分的な未sync変更や伸長を残し得るため、SQLiteのjournal／rollback処理に従う。
xReadは短いreadの残りを0にし、SQLITE_IOERR_SHORT_READを返す。
これは[SQLiteのVFS契約](https://www.sqlite.org/c3ref/io_methods.html)に従う。
負のoffset／length、0 byte read/write、短いreadの0埋め、未知のpathと重複open拒否もcallback試験に含めた。

grantはsqlite3_fileの一時的なopen/closeとは別に、storage bindingのlifetimeで保持する。
xCloseで他fileの未sync変更を暗黙にcommit／cancelしない。SQLite終了後にtrusted bridgeがbindingを終了する。
syncは引き続き同じbindingのvolume transaction全体を公開する。
SQLiteにatomic write・safe append・batch atomicの特性は広告していない。WAL／SHM／mmapは無効。

## 使用したSQLiteとパラメーター

未変更の公式amalgamation `sqlite-amalgamation-3540100.zip`を既存bootstrapでhash照合した。
archiveのSHA3-256は`92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`。
正確なbuild flagは[runner](../../tools/run-sqlite-store-test.sh)に保持する。
THREADSAFE=0、OS_OTHER、TEMP_STORE=3、DEFAULT_PAGE_SIZE=4096、OMIT_WAL、MAX_MMAP_SIZE=0、API_ARMORを使用した。
host libc allocatorを使い、既存のtask-owned allocator／native SQL serviceは変更していない。

各connectionで`page_size=4096`、`journal_mode=PERSIST`、`synchronous=FULL`、`temp_store=MEMORY`、
`cache_size=8`、`max_page_count=64`を設定した。page size・journal mode・sync値はqueryで照合した。
8 page cacheはspillを起こす試験用の目標であり、既定計画の512 KiB cache予算を置き換える推奨値ではない。
64行、各1,000 Bのblobとversion列、別のmarker tableを使い、全体整合を検査した。

[PERSISTのcommit処理](https://www.sqlite.org/atomiccommit.html)ではjournal headerを0にしてsyncする。
この順序を省略せず、以下の3点で所有する子processをSIGKILLした。

|停止位置|期待するSQL状態|結果|
|---|---|---|
|journal sync後|旧transaction|旧値、integrity_check=ok|
|DB sync後、journal無効化前|hot journalから旧transactionへ回復|旧値、integrity_check=ok|
|SQL COMMIT成功後|新transaction|新値、integrity_check=ok|

DB sync後のcaseでは、停止時のjournal magicが有効であることを確認した。
回復前にDB objectだけを別fileへ抽出し、journalを持たないhost SQLite readerで読むと、
64行のversion合計64・marker=1、integrity_check=okだった。
同じ元imageを通常のVFSで開くとhot journalが適用され、合計0・marker=0へ戻った。
回復後のDBも再抽出して照合した。単にstoreが古いrootへ戻っただけではない。
DBは77,824 B。抽出fileとrangeはarchiveに保存した。

## 結果とメモリ

8 positive case・1 negative control、20 process・4 SIGKILLが合格した。
明示的ROLLBACK、実際のSQLite page quotaによるSQLITE_FULL、device sync失敗からSQLITE_IOERRへの伝播、
serviceのpublication_unknown／recovery_requiredと停止、保存rangeからの再構築も含む。
SQLite page quotaの試験は、store allocatorの実NoSpaceを注入した試験とは異なる。

negative controlはxSyncを意図的に成功扱いにする別binary。
SQL COMMITは成功したが、世代は9のままsync 0回で、新processでは旧値が残った。
正しいverifierがSCALAR_MISMATCHで失敗し、続く旧値照合は成功した。compile失敗をcounterexampleに数えていない。

SQLiteの割当てhigh-water最大は193,232 B、約188.7 KiB。
Store・owner・queueの固定領域596,640 Bとの単純合計は789,872 B。
これはhost allocatorと今回のSQL workloadの測定・計算で、stack・process arena・stdio・backend・OS cacheを含まない。
実機peak、RV32 allocator配置／OOM挙動、query全般の上限や全機能同時実行を保証しない。
計画上のSQLite 2 MiB／store 2 MiB envelopeと512 KiB cache候補は維持する。

新値へのtransactionでbackend write 444 page要求、1,818,624 B、sync 20回、service要求345回だった。
この値は8 page cacheによるspill・journalと、COW data／map／rootの費用を含む。
実SD速度やwearの改善を示すものではない。より大きいcache候補との比較が次の測定課題となる。

CはWall／Wextra／Wconversion／Werrorでcompileし、2 sourceのClang static analyzer診断は0。
Zig Debug／ReleaseSafe各284件、Python 168件、format／ZLint／ShellCheck、既存RV32 compileと6 native ELF link／監査も合格した。
新しいSQLite VFS／C bridgeをRV32で実行・linkした結果ではない。
開発時のinclude不足・Zig API名・lint診断などの初回logも保存する。

[構造化結果](2026-10-28-sqlite-store-vfs.json)と
[archive](/Users/masanork/Documents/Codex/2026-10-28/nihos-sqlite-store-vfs-host)へsource・公式SQLite archive・binary・range・log・negative controlを保存した。
保持中の実機候補55 fileのhashは一致し、USB書込みは行っていない。
SIGKILLはOS cacheを失わせず、実電源断試験とは別の証拠である。

次は512 KiB cache候補とのI/O比較、bounded allocatorへの接続と実store NoSpace／追加I/O故障の試験を進める。
その後も一般VFSのfile lifecycle・lockingとの統合、native配置・stack・DMA・終了通知、
実SD書込み／除去／電源断、WAL、移動型cleanerは未完了gateとして残る。
