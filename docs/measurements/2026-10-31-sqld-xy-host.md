# sqld・xy・checkpoint storeのhost結合検証

対象source: `f4d3604b8e9beb067ff0cd27d99ec61a1bef37e4`、base: `e1cfd0caa2e426c07088c7b33ed77464cbf3d899`。全体のnative導入は未完了。
実装とbinding一覧は[契約](../planning/sqld-xy-service.md)、hashと実行ログは
[evidence/result.json](evidence/2026-10-31-sqld-xy-host/result.json)に保存した。

| 検証 | 結果 |
| --- | --- |
| sqld・実SQLite・Scheme結合 | 13件成功。SQL/本文を別processで再open、file byte I/O、truncate/remove、rollback、snapshot復元 |
| service境界 | wrong owner/principal/epoch、古いhandle、queue満杯、取消、transaction期限、I/O失敗後の全受理済み要求のcompletion |
| SQLite故障回復 | write/syncの51箇所×2故障model＝102ケース。再mount後のintegrity_checkと複数row不変条件を確認 |
| SQLite満杯 | 1 MiB/file上限でSQLITE_FULLとなり、成功応答済み全rowとintegrityを維持 |
| 既存Mac workspace | 16件成功 |
| Zig ReleaseSafe | 69/69 steps、837/837 tests成功 |
| Python discover | 538件成功。専用sqld試験を含むので件数を合算しない |
| checkpoint focused | 9件成功。pinしたvolumeの新世代への復元・stale token・再openを含む |
| 静的検証 | fmt、zlint 9 files、shellcheck、C analyzer成功 |
| RV32 | storeと新sqld/VFSのobject compile成功。新serviceのnative link/実行ではない |
| 通常ELF回帰 | UI/C6/read-only FS/新Scheme clientをlinkし、現sourceのmanifest・Flash区画・既存heap floor監査成功 |

通常ELFのprimary heapは49,216 Bで、49,152 B floorに対して64 Bだけ余裕がある。
新sqld core/SQLite VFSをこのELFへlinkしていないことをsymbolでも確認した。
通常worker stackは4 KiBのままであり、新serviceのstack/heapを資格化した結果ではない。

その測定はCIが落とすdefault connected image（network、devices、camera、xy、read-only FS）ではない。
storage clientの`std.fmt.parseInt`がSRAM `.text`へ入り、同じimageのprimary heapは48,320 Bまで下がって48 KiB floorを割った。
10進応答、UTF-8、Schemeの10進/16進リテラルはFlashの`.flash.xytext`で解釈する。
sqld coreを外した修正imageのprimary heapは49,344 Bだった。
通常起動はnormal storageとxyが有効なときsqldを同じdefault imageへ入れる。
Macでlinkしたそのimageは`.flash.sqldtext` 563,184 Bを含み、primary heapは50,624 Bで48 KiB floorを満たし、native image監査を通過した。

Mac GUIは新規の専用imageを一度だけ作成し、次回以降mountする。既存imageを自動でformatし直さない。
Schemeの`buffer/save!`→別process→`buffer/load!`でUTF-8原文を復元する。
`fs/restore!`はSQL行とfileをまとめて戻し、generationを増やして旧handleを失効させる。
RAM pinの復元であり、名前つき永続snapshot履歴ではない。

結合試験中、saveとloadの入口を区別する試験を追加し、それぞれ個別のdispatchにした。
provider未接続の旧`q`が空リストで成功していた経路も、明示的なエラーへ変更した。

実機アクセス・Flash書込み・SD書込みは実施していない。媒体のprovision、native owner task/allocator/stack、
RPC待機、実機での共存・再起動・抜去・電断は残る。WAL、durable operation receipt、GJS等のlarge pack、
ruby属性の保存も未提供。元のmain worktreeは編集せず、開始時と同じ4ファイルのstatus/numstatを確認した。

## Linux linkと時計境界の追補

source `f5dee0a5df57c42e7a5910320324d8685a7fff92`。初回Linux CIはZig objectの`__zig_probe_stack`未解決で失敗したため、
host objectへcompiler runtimeを明示した。無効なmonotonic clockでtransaction期限をoverflow
させない検査、OOM/時刻エラーの返却も追加した。callbackを差し替えず固定したまま時計値を
注入するhost試験で、未定義動作を避けている。

追補のsqld試験は14件、Python discoverは539件、既存Mac workspaceは16件成功。
C analyzerとshellcheck、更新したcore/VFSのRV32 object compileも成功した。
Zig sourceと通常ELFの関連sourceは先行記録から変更していない。
追補のhash・ログは同じresult.jsonのfollowupとfollowup-*.log.gzに分けて保存した。

## request slotの所有期間

source `b7eb893922cdb5f71846621c9e79fbec98b3ef7c`。request slotをproducerへ返す前にcompletionのsequence記帳を終える順序にした。
producerとSQLite ownerを別threadで動かし、送信元bufferを書換えながら256要求のcopyとcompletionを
確認する試験を追加。sqld 15件、Python discover 540件、C analyzer、RV32 object compileが成功した。
この追補はqueue_followupとqueue-*.log.gzへ保存した。Linux/Mac CIの初期link修正後の成功は
[Linux](https://github.com/masanork/nihos/actions/runs/41179535504)、
[Mac](https://github.com/masanork/nihos/actions/runs/41179535550)にある。これらはqueue追補前のheadの結果である。
