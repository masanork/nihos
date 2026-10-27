# 共有page mapによる部分更新

2026-10-27。実装commit `227685e`、branch `codex/store-crash-model`。
[前回の全object COW](2026-10-27-store-streaming.md)を避けるpage mapと、その参照を守るGCを追加した。
33 MiB＋17 Bのobjectで20 Bを変更するbackend write要求は、34,652,160 Bから36,864 Bへ減った。
host fileでの結果であり、実SDの速度・電源断耐性を確認したものではない。

## 形式とAPI

[extent_map.zig](../../src/storage/extent_map.zig)は4 KiB nodeを使うimmutable tree。
leafは252個のphysical data page参照とCRC32を保持し、internal nodeは126個の子参照・CRC・物理範囲summaryを持つ。
16 GiBの論理長で最大4段。媒体上のmapは約65.6 MiBとなるが、全mapをRAMへ読み込まない。
nodeは論理baseと担当page数に結び付け、将来EOFが変わっても無変更の完全subtreeを共有できる形式にした。
伸長・truncate API自体はまだ実装していない。

`promoteMapped(key)`は既存のblobを明示的にmapへ変換する。
dataをcopyせず、検証した既存sidecarからpage CRCをmap leafへ移す。
33 MiB objectではmap 35 pageとobject leaf・rootの計37 pageを書いた。
初期map構築はblockingで、新しいmap一式を置く連続空きも必要とする。

`patchMappedPage`／`patchMappedPagePrepared`は1つの論理page内の範囲を変更する。
変更data pageとmapの経路だけをCOWし、未変更のpageとsubtreeは共有する。
prepared版は事前に分割探索を完了してから呼ぶ。pageをまたぐ変更は複数stepを同一transactionに入れ、最後にcommitする。
従来のstream／patch APIも残り、従来のpatchは全copy方式のまま。

形式をversion 4へ更新し、blobとmappedをobject entryで区別する。
mappedの`Value.checksum`はmap rootのCRCで、blobの全体CRCとは意味が異なる。
mappedのverifyはmap経路と各data pageのCRCを確認する。
有効なCRCを持つ旧version 3 rootも、自動移行・formatせず拒否する。
利用者媒体や実機候補は更新していない。

## GCとRAM

GCは両disk root・staged root・reader snapshotからmap nodeとdata pageを追う。
map化済みの参照だけになれば、元blobのsidecarや未参照data pageを個別に回収できる。
blob readerが残っている間は元extent全体を保護する。
summaryはdataとnodeの物理範囲を分け、dataから離れたnodeも回収しない。
summaryはCRCに含め、nodeの内容から再計算して検査する。

探索のDFSは小さな固定配列で再開できる。node readもleaf visit budgetへ数え、1 visitは最大4 KiBのmetadata read。
途中にmapped readerを挟んでも、保持したobject leafとDFS状態を失わない。
metadata summaryは保守的なmin/maxであり、断片化時の探索量・実機latencyは別の測定gateとして残る。

|状態サイズ|cacheなし|512 KiB cache＋2 KiB tag込み|
|---|---:|---:|
|arm64|31,528 B|557,864 B|
|RV32 compile|31,512 B|557,848 B|

前回から4,408 B増え、主に4 KiB map buffer、cache tagとDFS状態を追加した。
writerの既存bufferを探索中のobject leaf保持にも使い、容量に比例するRAM配列を増やしていない。
caller buffer・stack・backend・OS file cacheは含まない。PSRAM配置・総RAM peakは未測定。
32 KiBの基本状態gate、640 KiBのcache込みgate、2 MiB store envelopeは維持する。

## 検証

[追加Zig test 10件](../../src/storage/extent_map_test.zig)で、promotion、pinされたblob／map view、128回の物理page再利用、
共有pageの保持、取消し、cache／媒体破損、探索budget、離れたinternal node、旧形式拒否を検査した。
promotionは50 event × 36条件で1,800中断、map更新・回収は84 event × 36条件で3,024中断を検査した。
各6件の正常ack後は新世代を回復し、途中では最後にackした世代以上の完全なdataだけを許容した。
有限な故障モデルの結果であり、全故障条件の証明ではない。

[negative control](../../tools/extent_negative_control.py)でdataのmarkを外すと旧readerのCRC検査が失敗し、nodeのmarkを外しても旧readerが壊れた。
node範囲summaryを無視すると離れたmap nodeを空きと誤計算した。
runnerは当初、node省略版に別の診断文字列を期待して止まった。実際の破損検出を確認し、期待するmarkerを修正して3件を再実行した。
既存の9件のnegative controlもcompile errorではなく期待した意味上の失敗を検出した。

16 GiB疎fileの9ケース・19 processで、33 MiB＋17 Bの全byte照合、map変換、2 pageにまたがる20 B変更、ack後のSIGKILL、GCと再構築を確認した。
旧方式は8,460 page、新方式は9 pageを書いた。削減率は99.89%。map変換の一度だけの費用は別に数えている。
無変更の69,287,936 Bの既存payload保存rangeはhashが一致し、再保存せず新しいmap/data 167,936 Bだけを追加した。
SIGKILLはOS cacheを失わせないため、実電源断とは区別する。

Zig Debug／ReleaseSafe各255件、Python 168件、format／ZLint／ShellCheck、RV32 map入口compile、既存6 native ELF link／配置監査が合格。
既存のstreaming・回収・checkpoint中断試験と、cacheありcheckpointの23 process試験も通った。
source、binary、range、失敗比較とログは[構造化結果](2026-10-27-store-extents.json)に記録した。
[archive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-extents-host)の120 fileのhashと、保持中の実機候補55 fileのhashを再照合した。

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
sh tools/run-stream-test.sh
python3 tools/extent_negative_control.py .tools/zig-0.17.0/zig
sh tools/run-static-analysis.sh
```

次はmapの伸長・truncate・末尾の0埋めと、複数page更新のmetadata書込みのまとめ方を検討する。
native service接続、実SD書込み・除去・電源断、移動型cleaner、SQLite永続VFS／WALは未実装・未検証のまま。
