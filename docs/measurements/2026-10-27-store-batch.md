# 複数page更新のmap・object leaf書込み集約

2026-10-27。実装commit `a85238a`、branch `codex/store-crash-model`。
[伸長・切り詰め](2026-10-27-store-resize.md)に続き、同じobjectの最大16 pageをまとめてCOWするAPIを追加した。
33 MiB＋17 Bのhost file内で16 pageを更新し、backend write要求を266,240 Bから81,920 Bへ69.23%削減した。
入力は各pageの1 byte、計16 B。実SDの速度・耐久性やSQLiteの実行結果ではない。

## APIと書込み

`MappedPatch { offset, bytes }`を論理page順に1〜16件渡す。
各patchは非空で1 page内に収まり、同じpageは重複できない。EOFを越える場合は先にresizeする。
callerは入力sliceをcall終了まで保持し、Storeやscratchの内部bufferとは共有しない。
入力の順序・範囲・件数をすべて検査してから書込みを始める。

`mappedBatchPages(length, patches)`で新規data＋map page数を計算する。
分割空き探索の完了後に`patchMappedBatchPrepared`を呼ぶ。blocking版は`patchMappedBatch`。
変更dataを先にCOWし、対象pageを含むmap nodeだけを下から再構築する。
共有するancestorは1回だけ書き、最後にobject leafを1回更新する。commitまではstaged viewのまま。
未変更のdata・subtree・pinされた旧readerは保持し、既存のGCで保護する。
媒体形式はversion 5のままで、既存のresize・1 page patchと同じtransactionで利用する構成である。

|33 MiB objectの16 page更新|従来の個別APIを16回|一括APIを1回|
|---|---:|---:|
|data page|16|16|
|map node|32|2|
|object leaf|16|1|
|commit root|1|1|
|backend write合計|65 page／260 KiB|20 page／80 KiB|

各pageの変更内容と最終file内容は両方式で同じものを使用した。
syncは両方式とも最後のcommitで2回。root retirementの追加1 pageは比較値に含めていない。
疎領域では対象の経路だけを生成する。別のleaf・上位subtreeに散った更新も処理できるが、共有率によって書込み量は変わる。

## メモリ

前回の16 KiB作業領域を`MapScratch`として共用し、`ResizeScratch`はそのaliasを維持する。
1つのownerがresizeとbatchを順に処理する場合、別々の16 KiBを確保する必要はない。
Store状態はRV32で31,512 B／cache込み557,848 B、arm64で31,528 B／557,864 Bのまま。
16件分のcaller descriptorはRV32 compileで256 B、hostで384 B。call内のCRC配列は64 B。
入力data・scratch・descriptor・stack・backendはStore状態サイズとは別に計上する。
prepared版でも一括call内のI/Oは同期実行し、16件制限は実行時間の保証ではない。
2 MiB store envelopeは維持する。PSRAM配置・実stack peak・near-full latencyは未測定。

## 検証

追加Zig testは7件。共有経路の書込み回数、commit前の旧view、旧reader、
不正な順序・重複・EOF越え・空入力・17件入力の拒否、prepared探索、rollback、BusyとNoSpaceを検査した。
16 GiB論理長の4段mapをまたぐ疎な更新と、そのGC・旧reader・再openも確認した。
16 page batchを64回繰り返し、小さな物理領域の再利用後も内容と旧readerを照合した。

|途中停止の対象|event数|中断条件数／mode|正常ack後／mode|
|---|---:|---:|---:|
|同じmap leaf内の2 page|82|2,952|6|
|別のmap leafにある疎な2 page|114|4,104|6|

3種のbackground writeback・2種のflush順・6種のsector切断位置で、各mode合計7,056中断を検査した。
ack後は新版、途中では旧版か完全な新版だけを許容する。
negative controlでは別subtreeのdata参照を誤って重複させるとCRC検査が失敗し、
parentへの更新参照を省くと内容照合が失敗した。前回のresize 2種・GC 3種のcontrolも再実行し、期待した意味上の失敗を検出した。

Zig Debug／ReleaseSafe各274件、Python 168件、format／ZLint／ShellCheck、RV32 batch入口compile、
既存6 native ELF link／配置監査が合格した。
host fileは15ケース・31 process・6 SIGKILL。batchのcommit前停止では旧fileを、ack後停止では全変更済みfileを回復した。
GC後のfileをrange snapshotから再構築し、全byte・CRCを再照合した。
既存の69,480,448 Bのpayload rangeはhashが一致し、再保存せず新たな18 page／73,728 Bとmetadataを追加した。
SIGKILLはOS cacheを失わせないため、実電源断とは区別する。

[構造化結果](2026-10-27-store-batch.json)と
[archive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-batch-host)へsource・binary・range・log・controlを保存した。
保持中の実機候補55 fileのhashは一致し、USB書込みは行っていない。
次はservice側のbuffer所有権・取消し・sync境界を定め、SQLite page write／truncateへ接続する。
永続SQLite VFS／WAL、native owner／配置、実SD書込み・除去・電源断、移動型cleanerは未完了である。
