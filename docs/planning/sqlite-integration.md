# SQLite integrationと永続VFSの契約

2026年10月27日。実装前の設計基準。[ADR 0002](../adr/0002-smp-services.md)の単一owner方針と
[filesystem VFS](filesystem-vfs.md)のmount・保存契約を前提にする。
API名と数値予算はPoCで確定する。既存のメモリDB試験は、永続DBやsqldの合格証拠にしない。
[2026年10月26日の候補実機記録](../measurements/2026-10-26-tab5-native-sqlite-physical.md)でも、
その候補ではSD経路・永続VFS・service RPCは未実装で、SQLiteの実機実行は未到達と区別されている。
これは10月26日の対象revisionの記録であり、別branchの後続SD読取り・service・メモリDB実機証拠を否定しない。
標準予算は[他の作業系統との整合](filesystem-vfs.md)に示す開発profile `67c991b`へ合わせる。

## 設計上固定すること

- SQLite libraryへの入口は一つのsqld owner taskに限定する。CPU1への永久固定はしない。
- 標準初期構成は一接続・一DB。まずread-only DBを扱い、永続更新は一つの書込み可能DBから始める。
  read-only packのATTACHは追加予算を確認する拡張profileとする。
- 初期の永続書込みはrollback journal `PERSIST`、`synchronous=FULL`、memory tempを使う。
  設定値だけで電断耐性が成立したとはしない。
- OS VFSが提供し、資格化したmount profileだけをDB書込みに使う。FAT/exFAT一般write対応とは別判定にする。
- clientにはDB/statement/transaction/row-batchの世代つきhandleを渡し、path・SQLite pointerを渡さない。
- timeout・取消・client切断を、未commitの証拠にしない。反映結果不明をAPIで表現する。

## service境界と接続の所有

```text
client ─ bounded request/completion ─ sqld owner
                                     |
                              SQLite VFS adapter
                                     |
                         storage service / OS VFS
```

同一ownerがprepare/step/reset/finalize、transaction、close、SQLiteの設定・初期化を担当する。
`SQLITE_THREADSAFE=0`を使うなら、別taskが別接続を開くことも初期は禁止する。
行batchの受渡し後も同じstatementを無制限に保持せず、期限・lease・client終了時の回収を管理する。
statementとtransactionはclient principal、権限集合、DB/schema世代に束縛する。
別clientへ切り替える際にactive transactionやstatement権限を引き継がない。

client単位の明示transactionには実行時間・idle時間・更新量の上限を設け、他clientの利用を独占させない。
満杯queueは即時に失敗させ、受理済み要求のcompletion領域を先に予約する。
ownerの停止・異常終了では、storageがbufferへ触れなくなるまで関連heapを回収しない。
一接続で満たせない独立性が必要になった場合は、接続数・heap・lockingを改めて測定して設計を変更する。

SQLite VFS callbackは同期関数だが、storageへの要求は有界RPCとして実行できる。
待機するsqld taskはparkし、storage owner・表示・音声を動かす。storageからsqldへの同期依存は作らない。
sqldの待機中にも取消flagを通知できるcontrol経路を持ち、通常RPC queueの処理だけに依存しない。

## DBの種類とopen policy

| DB | 初期policy |
| --- | --- |
| 学習pack | 配布時に閉じたDBを検証してread-only open。active fileの上書きは禁止 |
| 個人記録 | 管理directoryの単一write DB。資格化したmountだけでopen |
| SQL練習 | 本人専用DB。system DB・pack更新・任意path・危険な設定変更の権限を持たない |
| system DB | system専有。通常clientのSQL worksheetから参照不可 |

pack ID＋版からserviceが対象を解決する。client由来のfilename、URI query、VFS名をそのままopenへ渡さない。
`immutable=1`はread-only指定の代用にしない。実際に内容不変を保証できるpack leaseだけに限定する。
pack交換・外部writer・媒体再接続で不変条件が崩れる場合は旧接続を閉じて新世代でopenし直す。
cleanな配布DBはDB単体で開ける状態にして、未checkpointのWALやhot journalを同梱しない。
初期profileで扱えないWAL形式のDBは、PC importerで変換するか明示的に拒否する。

packのmanifest/hash検証後にも、SQLiteの整合性確認、schema/tokenizer版、対象table、ページ数等を
有界に確認する。hash一致だけでSQL内容が安全になるとはしない。
authorizer等でATTACH/DETACH、extension load、任意fileアクセス機能、policyを弱めるPRAGMAを制限し、
信頼できないschemaが危険なapplication functionを実行しないよう登録関数とschema trustを絞る。
cached statementも権限境界を越えて再利用しない。利用者へは型のある検索・保存APIを先に提供する。

read-only段階はpack自体を`main`として開く。標準初期profileは一接続・一DBとし、packと個人DBは
ownerがstatement/transactionを閉じて接続を切り替える。read-only packのATTACHは拡張profileに分け、
schema/cache分の予算を確認後に最大一つまで許可する。複数write DB・複数mountをまたぐ
transactionは公開しない。`main=:memory:`やWAL等によるATTACH全体のatomicity条件の違いを避ける。
pack IDへの参照と個人記録の保存は一つのwrite DBで完結させる。
根拠は[ATTACH仕様](https://sqlite.org/lang_attach.html)と[URIのimmutable条件](https://sqlite.org/uri.html)。

## SQLite VFS adapterの最低契約

OS VFSの通常APIとSQLite固有の戻り値を区別する。以下をhost試験の受入条件とする。

| callback/機能 | 契約 |
| --- | --- |
| `xOpen` | open flagsを検査し、実際のmodeを`pOutFlags`へ返す。read-write要求を無通知でread-onlyにしない。失敗時の部分資源と`pMethods`を正しく処理する |
| `xFullPathname / xAccess` | serviceが発行する内部名を同じ対象へ解決する。buffer不足は失敗。任意のglobal path探索はさせない |
| `xRead` | offsetと長さを検査。短い読出しの未読部分はゼロ埋めし、`SQLITE_IOERR_SHORT_READ`を返す。媒体errorをEOF扱いしない |
| `xWrite` | 分割した全量の書込みを確認して成功する。部分write・満杯・上限超過・抜去を黙って成功させない |
| `xTruncate / xFileSize` | 64-bit境界とbackend上限を検査。file sizeを転送長の型へ縮めない |
| `xSync` | data/metadataとdeviceへの反映を待つ。flagsを解釈し、必要なら強い同期へ引き上げる。失敗を成功にしない |
| `xDelete(syncDir)` | 要求されたnamespace永続化を含める。保証できないprofileではその操作を使うmodeを許可しない |
| `xLock / xUnlock / xCheckReservedLock` | SQLiteの段階的lock状態を同一fileについて管理する。全成功stubにしない |
| `xSectorSize` | 下位storageの故障影響単位とSQLiteの前提を照合する。logical sectorだけで値を確定しない |
| `xDeviceCharacteristics` | 初期は保守的な0。atomic write、safe append、powersafe overwrite等はadapterから媒体まで保証できたbitだけ追加する |
| `xFileControl` | 未対応opcodeは`SQLITE_NOTFOUND`。size hint等を受けても保証を偽らない |
| time/random/sleep | serviceを使う。wall clockとdeadline用monotonic clockを区別し、sleepでbusy loopしない |

`sqlite3_vfs.iVersion`と`sqlite3_io_methods.iVersion`は別のversionである。
初期file methodsはversion 1相当とし、WALのshared-memory methodsとmmapのfetchを使わない。
時刻の整数APIを使う場合のVFS versionは別に設定する。
`xOpen`のNULL名・一時file要求も扱いを定義し、memory temp方針に反するdisk spillを黙って許可しない。
動的extension loadingは無効にし、未対応のVFS機能へhost側の実装をfallbackさせない。
`xClose`でsync等に失敗してもerrorを返し、mountを必要に応じて回復待ちにする。close成功で耐久保存を代用しない。
詳細は[SQLite VFS object](https://sqlite.org/c3ref/vfs.html)と
[I/O methods](https://sqlite.org/c3ref/io_methods.html)を参照する。

SQLite offsetはsigned 64-bitで、OS VFSの非負offsetへ変換する前に負数・加算overflow・backend上限を検査する。
一回のSQLite要求がstorage転送上限を超えれば、有界の内部buffer/leaseで分割する。
分割中もfile handle・mount世代・lockは保持し、途中失敗では全体を失敗させる。

DBと`-journal`等の補助fileは同じmount・管理directory・権限に束縛する。
補助名の最大長も考慮し、名前衝突やclientによる先取り作成を防ぐ。
一つのDBに対する別path・LFN/8.3別名・大小文字違いにも同じ専有を適用する。
FatFsの`FF_FS_LOCK`はSQLite lockの実装ではなく、その下位の不正操作検出として扱う。
hot journalの存在確認は権限errorやI/O errorと区別し、読めないことを不存在と解釈しない。

## journal、同期、回復

初期設定は`journal_mode=PERSIST`、`synchronous=FULL`、`temp_store=MEMORY`、`mmap_size=0`。
open後に設定結果を確認する。read-only packにはwrite DBと同じjournal設定の変更を強制しない。
WAL、journal OFF/MEMORY、synchronous OFF/NORMALへの切替えは初期client APIで許可しない。
memory tempでもsort/FTS等の作業heapは増えるため、メモリ上限超過は正常な失敗として扱う。

`PERSIST`はjournalを毎回削除しない方針であり、初回create、容量拡張、directory更新、媒体故障をなくさない。
journal/header/DBのwriteとsyncの順序はSQLiteに任せ、adapterが独自にまとめて順序を変えない。
`FULL`が要求する保証はFS cache、block driver、媒体の完了までつながっている必要がある。
DELETE mode等を追加する場合はnamespace同期を含む別profileを検証する。
根拠は[atomic commit](https://sqlite.org/atomiccommit.html)と
[synchronous](https://sqlite.org/pragma.html#pragma_synchronous)。

通常fileのdurable replaceを提供できることは、DBのrandom overwrite＋journalの資格とは別である。
littlefsも個々のFS操作の回復だけでDB全体のtransactionを保証したことにしない。
FAT/exFATのmetadata破損でDBとjournalの両方へ到達できなくなる条件も故障モデルに含める。
媒体の故障影響が無制限・不明なら、その条件に対するDB耐久性を主張しない。

mount復帰後は新しい接続でSQLiteのjournal回復を行い、必要な整合性確認とアプリ不変条件の検査後に
write DBを利用可能にする。回復失敗時は元DBとjournalを保全し、自動削除・空DBでの再作成をしない。
read-only openで回復が必要なら、資格化した権限で回復するか`RecoveryRequired`として止める。
DB複製はactive fileの単純copyでは行わず、ownerが閉じるか、将来backup APIを資格化して提供する。
schema migrationもownerの有界transactionで実行し、version不一致と失敗時の復旧方針を持つ。

## エラーとcommit結果

| storageの状態 | SQLite adapter / clientへの扱い |
| --- | --- |
| EOFによる短いread | ゼロ埋め＋`SQLITE_IOERR_SHORT_READ`。通常row終端とは別 |
| 書込み先が満杯・file上限 | `SQLITE_FULL`。途中writeの副作用を隠さない |
| read-only | `SQLITE_READONLY`。open権限不足なら適切なopen errorも保持 |
| lock競合 | `SQLITE_BUSY`等。期限内の有界retryのみ |
| 抜去・stale・read/write/sync失敗 | 対応する拡張`SQLITE_IOERR_*`/open error。元のmount理由も保持 |
| heap不足 | `SQLITE_NOMEM`。statement/transaction状態と回収結果を確認 |
| client取消 | 安全に中断できた場合は`SQLITE_INTERRUPT`相当。commit結果とは別field |

公開結果は少なくとも`Committed`、`NotCommitted`、`OutcomeUnknown`を区別する。
read失敗・write失敗・中断のerror codeだけでtransactionの状態を推測せず、ownerがSQLiteの
autocommit/transaction状態とrollback・storage状態を確認する。
commitの成功応答を受けた場合は、資格化した故障モデル内で再mount後も反映されることを要求する。
commit発行後にtimeout/抜去/応答消失が起きた場合は、反映済みの可能性がある。
結果不明になったDBは後続writeを止め、終息・再open・回復・照合を経てから再開する。

型のある更新APIはoperation IDと内容digestを受け、更新と同じtransactionへreceiptを保存する。
同じID＋同じ内容の再要求には既存結果を返し、違う内容は`Conflict`にする。
receipt保持期限とIDのscopeをAPIに含め、期限外の再要求を新規更新として黙って再実行しない。
これで回復後の照合を可能にするが、媒体を失った場合まで結果を確定できるとはしない。
任意SQL worksheetはoperation IDだけで自動replayせず、結果不明を表示して利用者が状態を確認する。

## 取消とdeadline

取消flagはclient/operation世代と結び、ownerがprogress callback等から確認する。
別core/taskからSQLite APIを呼ぶ経路を初期は作らない。`sqlite3_interrupt`を採用する場合は
そのbuildのthreading条件、connection寿命、closeとの競合を別途証明する。
一要求の取消が、次に開始した要求まで巻き込まないように世代を検査する。

SQLのprogress callbackはstorage内で止まったI/Oを中断しない。
SQL実行量、busy retry、storage待ち、transaction leaseにそれぞれ上限を設ける。
取消受付、SQL停止、deviceの終息、buffer解放、rollback/commit照合完了を別々に観測する。
更新中の中断ではrollbackもI/Oを必要とし得るため、取消ボタンへの反応時間と回復完了時間を分ける。
service taskのkillや接続heapの解放で取消を代用しない。
根拠は[progress callback](https://sqlite.org/c3ref/progress_handler.html)と
[interrupt API](https://sqlite.org/c3ref/interrupt.html)。

## メモリと実行量の初期profile

以下は計画上の初期上限であり、既存fixtureで全て実現・検証した値ではない。
設定可能なSQLiteのlimitと、serviceが持つ上限を組み合わせる。

| 対象 | 初期案 |
| --- | --- |
| 接続・schema | 一接続・一DB。ATTACHは標準初期profileでは無効 |
| SQLite全体枠 | 2 MiB以内。cache、statement、temp、FTS作業領域、allocator overhead等を含むservice枠 |
| page cache | 512 KiBを目安に設定。hardな全体枠はallocator・admission側で別途強制 |
| SQL/statement | SQL長16 KiB以下、statement handle最大8個、同時実行一つ |
| 結果 | batch 32行かつ16 KiB以下、単一cell 8 KiB以下。大きい本文は専用chunk APIで取得 |
| request/lease | outstanding最大8個、同時row-batch lease最大2個。期限切れで安全に回収 |
| 実行・transaction | SQL progress budgetと期限を要求ごとに設定。初期transaction/idle上限は各2秒を仮置き |

SQLite allocator外のservice内資源も2 MiB枠に含め、RPC bufferとstorage/FS cacheはVFS/RPC/I/Oの
0.5 MiB枠、stack・DMA bufferは内部SRAMの対応枠へ重複なく計上する。
SQL実行量とtransactionの更新/I/O byte budgetはPoCで確定し、S4以降は値を省略できないprofile項目にする。
制限到達後もrollback・closeを完了できるように、通常要求用の枠と回復用buffer/要求枠を分けて確保する。
SQLite allocatorは`xSize/xRoundup`、alignment、realloc失敗時の旧領域保持、大きい連続allocationを検査する。
既存の小さなallocation向けpoolが任意query・FTS5の要求を満たすとは仮定しない。
最終buildのSQLITE compile options、page size、cache、allocator、FTS/tokenizerを固定し、OOMを再注入する。
期限2秒や取消50 msは媒体timeoutの実測で改める。未測定値をUI保証として公開しない。

## 検証段階と受入条件

全段階は未完了。FS形式・mount profileごとに証拠を残し、読取り合格をDB書込み合格へ流用しない。

| 段階 | 受入条件 |
| --- | --- |
| S1: host adapter | 全callback、flags、失敗open/close、zero fill、部分write、64-bit変換、lock・alias・補助名・権限を検査 |
| S2: host read-only | 実packで検索・chunk取得・ATTACH上限・schema制限・OOM・取消・不正DBを確認 |
| S3: host永続DB | 下記のcrash matrixで新規mountから回復。構造整合性とアプリ不変条件を確認 |
| S4: target service | owner制約、RPC飽和、client死亡、late completion、out-of-band取消、stack/heap、表示・音声との並行を確認 |
| S5: native実機 | exact firmware・媒体で電源断、抜去、満杯、reset、Flash guard、DMA終息を繰り返す |
| S6: app API | operation receipt、権限隔離、migration、結果不明からの再照合、再起動後の読書・記録継続を確認 |

S3のcrash matrixはjournalのcreate/extend/write/sync、DBのwrite/sync、journal headerの無効化/sync、
namespace更新の前後を含める。各I/Oでno-space、short write、I/O error、sync errorを注入する。
cacheを失った再openで、未同期writeの消失・並替え・torn writeを故障モデルに従って再現する。
commit済みと応答した更新が残り、未完了更新が旧状態か完全な新状態になり、部分transactionにならないことを調べる。
`PRAGMA integrity_check`に加え、相互参照、残高等の複数row不変条件、receiptとの一致を確認する。
初回DB作成、初回journal作成、容量拡張、rollback失敗、DB/補助fileの権限不一致、
journalがhotな状態でread-only openした場合、DBとjournalを取り違えた場合も含める。

大きいpackは2 GiB/4 GiB境界をhost sparse image等で検査し、FAT32上限は明確に拒否する。
性能はcold/warm query、断片化、満杯付近、row-backpressure、長時間transaction、
検索中の描画・音声・取消を同じworkloadで測る。
記録にはSQLite source/config hash、firmware hash、FS/driver/config、媒体、seed、
失敗位置、回復ログ、integrity結果、アプリ不変条件、commit判定、peak RAM/stack/latencyを残す。

最初の実装範囲はS1とread-only経路とし、永続更新はstorageのV3/V4とS3/S5を通したprofileから公開する。
WAL、複数write接続、DBをまたぐtransaction、FAT/exFATでの強い耐久保証は後続の独立した設計変更とする。
