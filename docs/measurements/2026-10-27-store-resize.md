# page mapの伸長・切り詰めと疎な0領域

2026-10-27。実装commit `5b906d4`、branch `codex/store-crash-model`。
[共有page map](2026-10-27-store-extents.md)へEOF変更を追加した。
切り詰め後に再伸長しても削除済みの内容は復活せず、pinされた旧readerには元の内容が残る。
host modelとhost fileでの検証であり、実機SDやSQLite永続VFSへの組込みはまだ行っていない。

## 表現と更新

未書込みの論理page／subtreeは、全byteが0の参照entryで表す。
readは0を返し、data pageは確保しない。書込み時だけ該当data pageとmap経路を生成する。
全体が未書込みの16 GiB論理objectを、4 KiBのmap root 1枚で表すテストが通った。
これは論理容量・アドレス・map深さのテストで、16 GiBのdata転送ではない。
実際に書き込める量には、媒体の管理領域・map・reserve・保護中の旧版の分だけ制限がある。

`mappedResizePages(key, length, scratch)`が必要な新規payload page数を事前計算する。
`beginPayloadSearch`／`stepPayloadSearch`で空きを分割探索し、`resizeMappedPrepared`でstaged viewを更新、最後にcommitする。
blocking wrapperの`resizeMapped`も残す。サイズの同じ変更は何も書かない。
非空blobは先に`promoteMapped`で変換する。空blobからの伸長と、blobを含む0長への切り詰めは可能。

完全なsubtreeは共有し、変更されるEOF側の経路だけ作り直す。
必要ならrootを追加・縮退し、完全なprefix subtreeへの縮退では新しいpayload pageを使わない。
境界data pageの一部を切り捨てる場合はCOWし、末尾以降を0にする。
旧EOFから伸長する際も境界を0にして、過去の物理page内容が露出しないようにする。
旧reader・両disk root・staged viewは既存GCの保護対象を維持する。

媒体形式はversion 5。page=0の参照に非0のCRCやsummaryがあれば破損として拒否する。
dataのないmap nodeもnode範囲で追跡・検証する。
有効CRCを持つversion 4 rootも書込み・自動format・移行なしで拒否する。
利用者媒体や保持中の実機候補は更新していない。

## メモリと書込み量

callerが固定16,384 Bの`ResizeScratch`を渡す。4段分のmetadata作業領域で、容量に比例しない。
Store自体の状態サイズは変わらず、RV32ではcacheなし31,512 B、512 KiB cache込み557,848 B。
host arm64では31,528 B／557,864 B。scratch・caller buffer・stack・backendはこの数値に含まない。
既定の2 MiB store envelopeにscratchも計上する。実機の配置とstack peakは未測定。
初期map変換や空き探索を含む処理時間、SD I/Oの待ち時間を保証するものではない。

33 MiB＋17 Bのhost fileを4,109 B縮小し、元の長さへ戻した。
縮小・伸長それぞれdata 1 page＋map 2 page＋object leaf＋rootの5 page、20,480 Bを書いた。
旧rootのretirement 1 pageを含む合計は45,056 B、sync 6回。全体copyは発生しなかった。
旧readerの末尾は元のpattern、新しいviewの末尾は0で一致した。
別processで再openし、保存rangeから再構築したfileでも全byteとCRCを照合した。
既存GCが過去の物理pageを再利用できるため、新世代は独立したrange snapshotを保存した。

## 検証と残る範囲

追加Zig testは12件。0長・page端・252 pageのmap境界・16 GiB論理長・旧reader・rollback・Busy・NoSpace・旧形式拒否を検査した。
36回の伸長／切り詰め／疎領域へのpatch／GCをbyte配列oracleと照合した。
空き不足はwrite前に拒否する。初回はtest fixtureで回収済みsidecar 1 pageを数え落として失敗したため、
blockerの長さを修正して再実行した。初回の失敗logもarchiveに保持している。

|更新|event数|中断条件数／mode|正常ack後／mode|
|---|---:|---:|---:|
|一部pageへの切り詰め|66|2,376|6|
|一部pageからの伸長|66|2,376|6|
|0長への切り詰め|34|1,224|6|
|空objectの疎な伸長|50|1,800|6|

3種のbackground writeback、2種のflush順、6種のsector切断位置を用い、各mode合計7,776中断を検査した。
ack後は新版、途中では旧版か完全な新版だけを許容する。有限な故障モデルの結果である。
末尾0化を除くnegative controlでは切り捨てたbyteが復活し、疎領域の0 readを壊すcontrolも内容照合が失敗した。
既存のdata／node保護・node summaryの3種のnegative controlも意味上の失敗を検出した。

Zig Debug／ReleaseSafe各267件、Python 168件、format／ZLint／ShellCheck、
RV32 resize入口compile、既存6 native ELF link／配置監査が合格した。
host file試験は11ケース・22 process・4 SIGKILL。SIGKILLはOS cacheを失わせず、実電源断とは異なる。
source・binary・range・log・negative controlは[構造化結果](2026-10-27-store-resize.json)と
[archive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-resize-host)へ保存した。
保持中の実機候補55 fileのhashも一致した。

次は複数page更新時のmap書込みをまとめ、SQLiteのpage write／truncateへつなぐservice側の契約を固める。
native owner／取消し／PSRAM配置、実SD書込み・除去・電源断、移動型cleaner、SQLite永続VFS／WALは別の未完了gateとして残る。
