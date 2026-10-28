# SQLiteの保存を成立させる

SQLのCOMMITが成功した。processを止めて開き直しても、新しい値が読めた。これで、SQLiteを保存できるOSになったと言ってよいだろうか。途中の書込みだけが残った場合や、成功を知らせる直前に止まった場合にも、同じ説明ができるだろうか。

{{ch:c-library}}ではメモリ上のDBを動かし、{{ch:durable-storage}}ではストアの公開順序を調べた。この章では両者をつなぐ。実際のSQLiteが要求する読書き、同期、journalの扱いを、小さいVFSで受け止める。実験はホストの通常ファイルで行う。

## 二種類のVFSをつなぐ

OSのVFSは、名前、権限、ファイルのhandleを管理する。一方、SQLiteのVFSは、SQLiteが利用するfile I/Oや時刻などをOSへ渡す接続口である。同じVFSという名前でも、引き受ける契約は異なる。

この段階の[SQLite VFS](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:probes/sqlite/store_vfs.c)は、汎用的な名前空間を作らない。既存の二つのobjectを`/main.db`と`/main.db-journal`へ対応させる。connectionは一つだけとし、WAL、共有メモリ、mmapは無効にした。一般のFatFs VFSとも、nativeのSQLite sessionとも、別のホスト実験である。

| SQLiteからの呼出し | この接続で必要になる仕事 |
| --- | --- |
| `xRead` | offsetから読み、短いreadの残りを0にする |
| `xWrite` | 必要な伸長の後、指定範囲を更新する |
| `xTruncate` | EOFを変更し、新しい末尾の意味を守る |
| `xSync` | ストアの公開を完了してから成功を返す |
| `xClose` | handleの寿命を閉じ、別fileの変更を勝手に確定しない |
| `xDeviceCharacteristics` | 検証していない原子的書込み能力を広告しない |

特に、通常ファイルのreadとSQLiteのreadは、EOF時の返し方まで同じとは限らない。短い読取りでは残りを0にして`SQLITE_IOERR_SHORT_READ`を返す。名前や型が合うだけでなく、呼出し元が結果をどう解釈するかを調べる。

## writeを受け付けても、保存はまだ終わらない

[ストアのサービス](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:src/storage/checkpoint_service.zig)は、要求とdataを固定長messageへコピーする。clientのポインタを残さず、最大4 KiBの要求を所有者が処理する。handle、接続世代、sequenceを検査し、返信枠を確保してから要求を実行する。

同じ接続からは、受付済みで未同期の値も読める。ただし返信の`staged`と、最後にsyncが成功した世代番号を分ける。write成功をdurableな成功通知へ変換してはいけない。

{{figure:sqlite-sync}}

図の最初の返信は、staged viewへ受け付けた応答である。後の`committed`は、参照先とrootの同期を済ませた応答になる。二つの返信を同じ「保存成功」と読まないことが、SQLiteの要求を下位の契約へ結びつける出発点になる。

このサービスのsyncは、その接続が持つvolume transaction全体を公開する。fileごとの独立transactionでも、SQL transactionそのものでもない。SQLiteのtransactionは、この下位の契約を使って別に成立させる。

clientが終了した場合、未同期の変更と未実行の要求は捨てる。一方、sync済みの変更は、成功返信をclientがまだ読んでいなくても残す。[サービスの試験](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:docs/measurements/2026-10-28-store-service.md)では、この未読返信の境界も調べた。利用者へ届いた通知と、媒体へ成立した公開は同じ時点ではない。

## journalを残す方式から始める

SQLite 3.54.1を、4 KiB page、`journal_mode=PERSIST`、`synchronous=FULL`、一つのconnectionで動かす。PERSISTでは、commitのたびにjournal fileを消す代わりに、そのheaderを無効にして再利用する。

旧pageをjournalへ残して同期し、DBのpageを更新して同期し、最後にjournalを無効にして同期する。途中で止まったとき、回復に使うjournalが有効かどうかで結果が変わる。

{{snippet:sqlite-vfs-sync}}

`flags`を利用する最適化はしていないが、syncそのものは省略しない。ここで成功だけを返すと、SQLiteのCOMMITは成功したように見えても、ストアの世代が進まない場合がある。

[実験記録](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:docs/measurements/2026-10-28-sqlite-store-vfs.md)では、この処理を故意に成功扱いへ変えた別binaryを作った。SQL COMMITは成功したが、別processでは旧値が残り、正しい検査器が`SCALAR_MISMATCH`で失敗した。APIの戻り値と、実際の仕事の対応を確かめる負例である。

## DBに新値があっても、commit済みとは限らない

試験は64行のdataと別のmarkerを一つのSQL transactionで更新する。runnerは自分で起動した子processだけを、次の三箇所でSIGKILLする。

| 止める時点 | 再open後に確認する値 |
| --- | --- |
| journalのsync後 | 旧transaction |
| DBのsync後、journal無効化前 | journalで旧transactionへ回復 |
| SQL COMMIT成功後 | 新transaction |

二行目は、単にストアが古いrootを選んだ結果ではないことも確認した。回復前のDB objectだけを抽出し、journalのない別fileとして読むと、64行のversion合計は64、markerは1だった。同じ元imageを通常のVFSで開くと、有効なjournalが適用され、合計0、marker 0へ戻った。回復の前後で`integrity_check`も通った。

ファイル内部が構造として読めることと、最後に確定したSQL transactionを読んでいることは違う。DBだけを抜き出す操作は、この違いを調べるための実験であり、運用中のDBを安全にbackupする一般手順ではない。

SIGKILLではOSのcacheが残る。ここで確かめたのはprocessの寿命と実SQLiteの回復手順であり、実SDへの電源断試験は別になる。

## エラーは、必ず元へ戻ったという意味ではない

サービスがcommit中のI/O errorを受けると、`publication_unknown`となり、その接続での後続操作を止める。書込みがどこまで残ったかを、その場で成功やrollback済みへ丸めない。

SQLiteへは、容量不足なら`SQLITE_FULL`、同期なら対応する`SQLITE_IOERR`を返す。write途中に未同期の変更や伸長が残る場合もあるので、その後のjournalとrollbackの処理に従う必要がある。

また、SQLiteのpage数上限によるFULLと、ストアが本当に空きを失った場合のNoSpaceは異なる。この参照版で確認した前者を根拠に、後者の全経路まで確認済みとはしない。エラーの名前を揃えるだけで、発生条件や残る状態まで同じにはならない。

## キャッシュの目標値と、割当ての上限

小さいcacheは、少ないRAMで動く一方、更新の途中でdirty pageを追い出すspillを増やし得る。[cache比較](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:docs/measurements/2026-10-28-sqlite-cache-bounded.md)では、同じ652 KiBのDBを更新し、最終DBの全byteが一致する条件で比べた。

| 構成 | backend write回数 | backend sync回数 |
| --- | ---: | ---: |
| host allocator、32 KiB目標 | 4,008 | 164 |
| host allocator、512 KiB目標 | 3,590 | 12 |
| 上限付きallocatorと外部page cache | 3,590 | 12 |

writeは10.43%、syncは92.68%減った。ただし、これらはbackendへの要求回数であり、実SDの時間や消耗を測った結果ではない。

SQLiteの`cache_size`は目標値であって、全malloc量のhard capではない。そこで別のbinaryを`SQLITE_ZERO_MALLOC`で構築し、登録した割当器以外へ逃げないことを調べた。page cacheは外部の512 KiB bufferへ、小さいobjectはtask所有のサイズクラスへ置く。

512 KiBすべてがpageの本文になるわけではない。今回のhostではheader込みのcellが4,368 Bとなり、120 cell、data相当は480 KiBだった。nativeでは、そのbuildのheader寸法から計算し直す必要がある。

## 少数の大きい要求を、どう扱うか

小さいobjectの要求だけを見ていたら、`integrity_check`が8 KiBのscratchを要求した。既存の小object用poolの上限4 KiBには収まらない。

host限定の試験では、8 KiBまで、同時一本だけの経路を別に作った。小object用の64 KiB parentに加え、scratchのbuddy reservationは最大16 KiB。page cacheを合わせた既知の予約は次のようになる。

| 領域 | 上限 |
| --- | ---: |
| 外部page cache | 512 KiB |
| 小object用parent | 64 KiB |
| 大きいscratch用buddy block | 16 KiB |
| 合計 | 592 KiB |

mallocのhigh-waterが約25 KiBだからといって、必要量を25 KiBと報告してはいけない。上の予約、サービスとqueue、管理情報、stack、backendを別に数える。今回の経路ではscratchが残る間のparent closeを拒否し、別taskや内部ポインタからの解放も拒否した。nativeのallocator ABIを、このhost用の変更で置き換えたわけではない。

## 失敗したprobeと、失敗したCOMMIT

通常更新が通る300回のmalloc／reallocの一回ずつへNULLを注入し、各回の終了後に別の正常processでDBを開いた。文、connection、SQLiteを閉じ、task parentと共有heapの回復も確認した。

300回のうち218回は旧値、82回は新値を保持した。後者はCOMMIT自体が成功した後、後続の検査でOOMになった回だった。probe全体が不成功でも、COMMITまで失敗したと解釈してはいけない。

全回で旧値か完全な新値を読み、`integrity_check`も通った。これは固定したSQLと注入地点の結果で、任意のqueryやschemaのメモリ上限ではない。処理を段階に分けて記録すると、失敗が起きた後にも成立している約束を説明できる。

## PC上で、実SQLiteの回復を観察する

```sh
git worktree add --detach ../nihos-book-sqlite-save \
  6bb2467ac14e7cc90b4bc2dde3f45c72360ca420
cd ../nihos-book-sqlite-save
sh tools/run-sqlite-store-test.sh
```

runnerは固定版のSQLiteを取得・検査し、新しい通常fileと子processを使う。出力は`build/sqlite-store/process.*`へ保存する。疎fileの論理容量は16 GiBだが、その全体を読み書きする実習ではない。既存のDBや実カードには接続しない。

[runner](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:tools/sqlite_store_probe.py)で三つの停止位置と、journalを分離した読取りを追おう。次にsyncを省いた別binaryについて、COMMITの返り値、ストアの世代、再open後の値を表にする。

追加実験の`sh tools/run-sqlite-cache-test.sh`はcacheの比較と300箇所のOOM再生を行うため、多くのprocessを起動する。先に小さい回復試験の意味を説明できるようにしてから取り組むとよい。

将来のWALとストアの統合には、重複した書込みを減らせる可能性がある。今回の実績は、その目標とは分けたPERSIST方式の接続である。nativeへの配置、実SD、電源断、汎用VFSとのfile寿命・排他の接続を確かめながら、比較の基準になる保存経路を育てていく。
