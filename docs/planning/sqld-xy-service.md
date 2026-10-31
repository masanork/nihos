# sqld・checkpoint store・xyの接続

2026-10-31。実装済みの共通層とhost adapterの契約。
Tab5の通常起動でsqldが常駐した、SDへ保存した、電源断に耐えたという記録ではない。

## 実装した経路

```text
Scheme / xy document -> copy-only provider -> bounded sqld request/completion
    -> single SQLite connection -> SQLite VFS -> checkpoint store
    -> host regular-file read/write/fsync
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
- progressは100 VM instructionごと、最大1024 callback。明示SQL transactionはmonotonic clockで2秒lease。
  期限切れはrollback後にtimeoutを返す。storage callbackの中断期限や実機UI応答時間の保証ではない。
- Schemeの既存cell/depth/step/text上限は維持する。大きな行結果はVM側でも拒否し得る。

`sh tools/build-xy-mac.sh`でMac appを作る。通常GUIは
`~/Library/Application Support/nihos/xy/store.img`を新規作成し、その後はmountする。
既存imageのmount失敗で再初期化しない。開けなくてもeditorは起動し、storage操作はエラーにする。
`--store PATH --create-store`は新規pathだけ、`--store PATH`は既存imageを使う。

## 残るnative gate

Tab5通常イメージのScheme clientにはproviderが未登録なので`Storage unavailable`を返す。
以下が終わるまで、通常OSのsqld常駐・SD永続化を主張しない。

1. 専用SD regionまたはfile containerを、既存データと衝突せずにprovisionする。
   region grant・shared SDMMC owner・write DMA fence・媒体syncをnative backendへ接続する。
2. SQLite allocatorとowner task、充分なstack、copied RPCとpark/wakeupを通常起動へ接続する。
   host mallocや同期in-owner callbackをnativeの証拠にしない。
3. exact imageでUI/input/C6との共存、再起動読戻し、満杯・抜去・I/O失敗・取消を確認する。
   clean OFF/ONと物理電断も独立して必要。

今回の通常ELFはprimary heap 49,216 Bで、既存49,152 B floorとの差は64 B。
既存worker stackは4 KiBのまま。新serviceの状態・SQLite heap・stackをここへ無検証で追加できない。
このELFには新しいsqld core／SQLite VFSをlinkしていない。

SQLite契約の参照: [VFS](https://www.sqlite.org/c3ref/vfs.html)、
[file methods](https://www.sqlite.org/c3ref/io_methods.html)、
[atomic commit](https://www.sqlite.org/atomiccommit.html)。
