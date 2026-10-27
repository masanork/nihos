# 実験storeのcopy所有service・取消し・sync境界

2026-10-28。実装commit `970466b`、branch `codex/store-crash-model`。
[複数page更新](2026-10-27-store-batch.md)を、固定長mailbox越しのsingle-owner service coreへ接続した。
host上で実際のCOW storeとfile backendを使う。既存native read-only storage RPC、別branchのVFS、SQLiteにはまだ接続していない。

## 所有権と操作

[checkpoint_service.zig](../../src/storage/checkpoint_service.zig)は認証済みの1 client binding、既存objectへの最大16 handleを扱う。
principalには再利用されないscheduler task identity／generationをtrusted入口から与える契約で、client要求はprincipalやobject keyを指定しない。
ownerが`grant`したhandle、endpoint epoch、sequenceを検査する。close・再bind後の古いhandle、古いepoch、古いtask終了通知を拒否する。
handle世代とepochはwrapせず、sequenceが0へ達したbindingは新しい要求を受け付けない。

要求はread／write／batch／truncate／stat／sync／cancel／close。
data最大4 KiBと最大16 fragment descriptorを値でcopyし、clientのpointerを保持しない。
batchは同じobjectの異なるpageを論理順に指定する。fragmentのdata範囲は要求の4 KiB内に収まり、同じ範囲の再利用は可能。
異なる16枚の4 KiB pageを1つの要求に載せられるという意味ではない。
通常writeは1つの連続範囲で、page境界を越えた場合は内部で2つのpatchへ分ける。
EOF越えは拒否し、伸長は先に明示的なtruncate要求で行う。作成・名前解決・削除は未対応。

Storeへ`getStaged`／`readStaged`を追加した。
同じownerは受付済みの変更を読めるが、通常のcommitted readとpinされた旧readerには未公開のままである。
返信の`visibility=staged`と`generation=最後にsyncが成功した世代`を区別し、write成功をdurable ackにしない。
syncはbindingが所有するvolume transaction全体をcommitし、F1→root→F2の完了後だけ`committed`と新世代を返す。
異なるfileごとの独立したtransactionや、SQLite transactionの意味は提供していない。

cancelは同じbindingの未sync transaction全体をrollbackする。closeは未sync transactionがある間Busyで、暗黙にcommit・discardしない。
client終了は、そのtaskが停止し、同期device callbackからownerが戻った後のtrusted hookで処理する。
進行中の空き探索を含めてrollbackし、pending／queued要求と未読返信を破棄、handleを失効、mailbox slotのcopyを消去する。
sync済みの更新は、返信が未読でも保持する。新clientへの再bindはcleanup・queue drain後だけ許す。

commit中のI/O errorは`publication_unknown`、後続操作は`recovery_required`となる。
read中のerrorでも部分的な返信dataを消去し、接続を停止する。回復前のretryや再bindは行わない。
device callbackはerror／timeout時も渡したbufferへのアクセスを止めてから戻る契約で、継続DMAの停止は未実装。

## 分割処理とメモリ

reply creditを確保してから要求を取り出す。reply満杯時に書込みを実行しない。
空き探索は`step`ごとに指定budgetで再開する。実際のbatch write・resize・commitは同期処理で、時間上限や優先度制御の保証ではない。
SQLite側のpage cacheを前提に、serviceには別の64 KiB cacheを追加していない。

|固定領域|arm64 host|RV32 compile|
|---|---:|---:|
|Store（512 KiB cache込み）|557,864 B|557,848 B|
|service owner（16 KiB scratch・pending copy・handle込み）|21,112 B|21,104 B|
|要求2＋返信2のqueue|17,664 B|17,664 B|
|合計|596,640 B|596,616 B|

Requestは4,408 B、Responseは4,144 B。stack・client buffer・backend・OS file cacheは含まない。
2 MiB store envelope内の固定領域の計算であり、全機能を同時に動かしたpeak測定ではない。
既存native read-only RPCの8 KiB reservationをこのABIで置き換えてはいけない。
PSRAM配置、task stack peak、DMA・quiescence・device removal、schedulerへの終了通知接続は未検証。

## 検証

追加Zig testは10件。コピー後のclient buffer変更、staged read、sync・cancel・closeの境界、
4 GiB越えの疎な伸長、順序・範囲・権限・epoch・handle拒否、table／sequence／epoch世代の失効、
reply backpressure、探索中終了、NoSpace後の既存staging保持、部分read errorのdata消去、
未読durable返信を含むclient終了・再bindを検査した。
4 KiBの同一fragmentを16 pageへcopyするcaseも、元bufferを変更した後の全byteと書込み回数を照合した。

2 objectをstageしてsyncする経路について、114 event × 3 background × 2 flush順 × 6 sector切断位置、
各modeで4,104中断と6正常ackを検査した。回復後は両objectとも旧版か、両方新版だけを許容する。
staged更新を誤ってcommittedと表示するcontrolと、終了時rollbackを省くcontrolは、期待した意味上の失敗を検出した。

Zig Debug／ReleaseSafe各284件、Python 168件、format／ZLint／ShellCheck、RV32 service入口compile、
既存6 native ELF link／配置監査が合格。
16 GiB疎fileの6ケース・11 process・2 SIGKILLで、sync前後停止、client終了、未読sync返信、
再bind時の古いepoch／handle拒否、4 GiB越えの末尾dataとrange再構築を確認した。
4 GiB分を転送・全走査した結果ではない。実際の保存payload rangeは122,880 Bで、metadataを含め1,179,648 B。
初回はhost filesystemの割当てが4 MiBを少し越えて疎file検査だけ失敗した。全内容caseは既に通っており、
OS側のallocation granularityを許容する16 MiBの上限へ直して再実行した。初回結果も保存する。
SIGKILLはOS cacheを失わせず、実電源断の証拠にはならない。

[構造化結果](2026-10-28-store-service.json)と
[archive](/Users/masanork/Documents/Codex/2026-10-28/nihos-store-service-host)にsource・binary・range・log・controlを保存した。
保持中の実機候補55 fileのhashは一致し、USB書込みは行っていない。

別worktreeのVFS契約 `ba573c4` はread-onlyで参照しただけで、取り込んでいない。
4 KiB量子・u64 offset・同期callbackの条件は合わせられる一方、VFSのpath／mount／writer排他・Transferへの変換、
create／truncate接続、SQLiteのfile lifecycle・locking・PERSIST journal・xSync error処理は残る。
次はこのserviceを使うhost SQLite VFS adapterを作り、実SQLiteのtransaction・回復試験へ進める。
native配置・終了通知・実SD書込み／除去／電源断、移動型cleaner、WALは別の未完了gateである。
