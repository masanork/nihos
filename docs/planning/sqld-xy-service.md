# sqld・checkpoint store・xyの接続

2026-10-31。共通層・host adapter・Tab5通常起動の実装契約。
Tab5ではSDへの保存とwarm reboot後の読出しを実測した。物理電断耐性は未認定。[実機報告](../measurements/2026-10-31-sqld-native.md)に候補・ログ・認定範囲を記録した。

## 実装した経路

```text
Scheme / xy document -> copy-only provider -> bounded sqld request/completion
    -> single SQLite connection -> SQLite VFS -> checkpoint store
    -> host regular-file read/write/fsync
    or native CPU0 SD owner (copied block RPC + scheduler parking)
```

旧固定フォーム評価器の`q`も同じproviderへ接続した。provider未登録はエラーであり、
検索結果の空リストにしない。MacのGJS辞書callbackとworkspace.dbのソース履歴は別adapterである。

core自身はthread生成やMMIOを含まず、ownerが`nih_sqld_step()`を繰り返す。
要求とcompletionは各4枠。結果枠を予約する前に実行しない。requestはコピーし、
authenticated principal・endpoint epoch・単調増加sequenceを照合する。
SQLite呼出しは登録ownerだけに限定する。I/O結果不明の後は新規要求を拒否し、
受理済み要求には結果不明のcompletionを返す。停止前にqueueを回収する必要がある。

`build/sqld/sqld-host --create NEW_IMAGE`または`--serve IMAGE`でstdio経由の継続受付を行う。
各入力行は`operation handle offset count text`、応答は
`service_status sqlite_code outcome sexp`。これは試験transportで、network APIではない。
Cocoa adapterは同じowner内の同期呼出しを使う。別taskから待つnative clientには、
request/completionとschedulerのpark/wakeupを接続する必要がある。

## 保存・回復の意味

SQLiteは`PERSIST`、`FULL`、memory temp、mmapなし、WALなし。固定内部名のDB/journalだけを扱う。
任意path、disk temp、別接続、ATTACH、clientによるPRAGMA変更を拒否する。
file methodsはversion 1、device characteristicsは0。短いreadは残部をゼロにしてshort-readを返す。
syncはdataとrootのbarrierを完了してから成功する。lockは一接続・fileごとの一handle・
排他的な媒体leaseのadmissionとlock状態に基づく。この排他を守れないbackendは接続できない。

一般ファイルのwrite/truncate/removeはstagingで、`fs/sync!`まで耐久保存ではない。
`fs/rollback!`は未commit変更を破棄する。SQL transaction中のファイル操作と、
ファイルのstaging中のSQLを拒否し、両方を一つの公開transactionと見なさない。
I/O/sync失敗はcommit結果不明として停止し、同じinstanceで更新を続行しない。
raw SQLの自動再送や、再起動を越えるoperation receiptは未提供。

`fs/snapshot`はcommit済みvolumeをpinする。`fs/restore!`はSQLiteがautocommitで
ファイルのstagingもない場合に接続を閉じ、pinしたrootを**新しいgeneration**として公開し、
DBを開き直す。SQLと一般ファイルの両方が戻り、古いfile handleは失効する。
tokenは現在のmountだけで有効、最大4個。名前つき永続履歴ではない。
GCはcurrent・retained root・pinから到達可能なpageを保護する。

`buffer/save!`は本文を256-byte以下のchunkでstagingし、syncまで完了する。失敗時はrollbackする。
`buffer/load!`は全byteとUTF-8を確認してから本文を置き換え、undo履歴を破棄する。
ruby属性の保存は未対応。Scheme評価エラーでVM/文書を戻しても、先に成功した永続commitは戻さない。

## Scheme入口

| 手続き | 意味 |
| --- | --- |
| `(sql/query sql)` / `(sql/exec! sql)` | read-only行取得／行を返さないSQL |
| `(sql/begin!)` / `(sql/commit!)` / `(sql/rollback!)` | 単一clientの有界SQL transaction |
| `(sql/check)` | ownerが固定のintegrity_checkを実行 |
| `(q 'notes #:where text #:limit n)` | notes(id,body)の検索。検索語をbindする |
| `(fs/open name [create?])` | handle取得。`#t`で未作成fileを作る |
| `(fs/read handle offset count)` | 最大64 byteを整数リストで読む |
| `(fs/write! handle offset data)` | 文字列またはbyte整数リストを書く |
| `(fs/truncate! handle size)` | 長さ変更。拡張部分はゼロ |
| `(fs/stat handle)` / `(fs/list)` | file長／名前一覧 |
| `(fs/remove! handle)` / `(fs/close! handle)` | 削除のstaging／handle解放 |
| `(fs/begin!)` / `(fs/sync!)` / `(fs/rollback!)` | ファイル更新の開始・保存・破棄 |
| `(fs/snapshot)` / `(fs/restore! token)` / `(fs/release! token)` | pin・復元・解放 |
| `(fs/collect!)` / `(fs/space)` / `(fs/generation)` | GC・容量・現在世代 |
| `(fs/verify handle)` | file全体のchecksum確認 |
| `(buffer/save! name)` / `(buffer/load! name)` / `(buffer/text)` | 本文の保存・読込み・取得 |

`fs/space`は`(media容量 payload空き 最大連続空き index空き)`をbyte単位で返す。
`sys/config-rollback!`は従来どおりRAMの表示設定だけを戻す。
`q`は現在notesだけを公開し、GJS/books/system DBのpack adapterではない。

```scheme
(buffer/insert! "保存する文章")
(buffer/save! "draft.txt")
(define checkpoint (fs/snapshot))
(buffer/insert! " 後の編集")
(buffer/save! "draft.txt")
(fs/restore! checkpoint)
(buffer/load! "draft.txt")
(fs/release! checkpoint)
```

## 初期上限と起動

- image 4 MiB、単一file 1 MiB、名前16個、handle16個、名前47 UTF-8 bytes。一階層の専用namespace。
- SQLはC APIで511 bytes、Scheme文字列は64 bytes。結果は8行×4列以内、cellはi32/NULL/64-byte以下のTEXT。
  float/BLOBや上限超過を拒否する。encoded結果は1024 bytes以内で、部分結果を成功にしない。
- SQLite heapは2 MiBのhard limit。store状態38,712 B、service状態7,072 Bはhost ABIの値で別枠。
  native常駐予算やRV32の値ではない。
- progressは100 VM instructionごと、最大1024 callback。明示SQL transactionはmonotonic clockでhost 2秒・native 30秒lease（platform指定、最大60秒）。
  期限切れはrollback後にtimeoutを返す。storage callbackの中断期限や実機UI応答時間の保証ではない。
- Schemeの既存cell/depth/step/text上限は維持する。大きな行結果はVM側でも拒否し得る。

`sh tools/build-xy-mac.sh`でMac appを作る。通常GUIは
`~/Library/Application Support/nihos/xy/store.img`を新規作成し、その後はmountする。
既存imageのmount失敗で再初期化しない。開けなくてもeditorは起動し、storage操作はエラーにする。
`--store PATH --create-store`は新規pathだけ、`--store PATH`は既存imageを使う。

## Tab5通常起動

公開device buildはxy + normal storage構成でsqldを既定で有効化する。
`NIHOS_NATIVE_SQLD=0`で従来のread-only FAT構成を選べる。
SQLite ownerはCPU0の独立task。2 MiBのboot-owned PSRAM予約にstore・service・
1 MiB memsys5 heap・512 KiB write-through read cache・64 KiB SQL stack・64 KiB Scheme stackを置く。
一般heapへ渡す範囲から予約分を除外する。SDコントローラは既存CPU0 storage ownerだけが操作し、
コピー済み512-byte要求で待機する。待機中の表示・入力・C6を継続する。
Scheme評価中の入力は遅延し、完了後の結果に新しい画面revisionを発行する。

媒体はMBRの`NIHSQLD1` marker、type `0xda`、LBA 2048から8192 sector（4 MiB）の専用store。
FATハンドルを失効させた後、この範囲だけに書込み権限を渡す。
通常buildのprovision CIDは0で、未知のカードや壊れたrootを自動初期化しない。
明示的な試験初期化では`NIHOS_NATIVE_SQLD_PROVISION_CID=0x...`を指定し、実カードCIDのCRC32一致を要求する。
これは誤操作防止であり暗号学的なカード認証ではない。初期化はpartition mapとroot metadataを作成し、secure eraseは行わない。
初期化候補を残さず、最後はCID指定なしの通常imageへ戻す。

native allocatorは`SQLITE_OS_OTHER`、`SQLITE_ENABLE_MEMSYS5`、`SQLITE_ZERO_MALLOC`、
`SQLITE_OMIT_DESERIALIZE`を組み合わせ、未登録default VFSに依存せず初期化する。
SQL壁時計は未公開で、時刻取得callbackは利用不能を返す。snapshot tokenはmount内だけで有効。
媒体抜去後の無停止再接続、満杯・実媒体I/O故障・取消の全経路、clean OFF/ON、物理電断は別の認定項目。

`tools/qualify-sqld-native.py`は排他write lockとserial kernel exclusionを取り、Flash全体の退避・
同一候補の書込み前後照合・Scheme操作・warm reboot読戻しを行う。バックアップはprivateに保持する。

SQLite契約の参照: [VFS](https://www.sqlite.org/c3ref/vfs.html)、
[file methods](https://www.sqlite.org/c3ref/io_methods.html)、
[atomic commit](https://www.sqlite.org/atomiccommit.html)。
