# 実カード接続前のvolume admission

2026-10-28、実装 `773c1da`（base `77dd74f`）。trusted ownerがFatFsへ渡す領域を検証する
[volume probe](../../src/storage/fatfs_volume.c)を追加した。
[契約とnative接続順序](../planning/volume-admission.md)、[構造化結果](2026-10-28-volume-admission-host.json)、
[実行結果JSON](evidence/2026-10-28-volume-admission/)に判断と根拠を保存した。
これはhost試験とRV32 object compileの結果で、新たな実機試験ではない。

superfloppyとMBR primaryのFAT12/16/32・exFATを対象にする。AUTOで複数候補を見つけたら拒否し、
明示選択は物理slot 1..4とする。全entryの範囲と重複を検査してからVBRを読み、
FAT/heap/root等のgeometryを確認して宣言長へ狭めたviewを返す。
GPT/extended partition、512 B以外のsector、固定FatFsが対応しないexFATの二重FAT等は対象外である。

53ケースの契約試験が成功した。範囲外、末尾entryの破損、未選択entryとの重複、候補重複、
32 bit終端の循環と2^32-sector deviceの終端境界、破損geometry、巨大shift、I/Oの途中失敗、
出力非公開とscratch clear、入力と出力の重複を検査した。
hidden-sector / PartitionOffsetが物理I/Oを移動しないこと、type 0x07の非FAT候補とFATの混在も確認した。
一回のprobeは最大5 read、caller-owned scratch512 Bで、heapやglobal stateを持たない。

さらに本体のrange / overlap / ambiguity / declared-length / exFAT shift検査を外した5種類のC sourceを
個別compileして同じ試験を実行し、全て検出した。shiftの改変はUBSanも停止させる。
これは今回の境界検査を試験が検出する負例で、任意破損やsilicon上のfault注入を網羅するものではない。

既存の実FatFs disk読取り5形式は、fixtureが与えた範囲からvolume probeの出力へ切り替えた。
guarded Backendと実Zig VFSにも同じ接続の5ケースを追加し、既存RPC/broker寿命試験を含む74シナリオが成功した。
各入力imageはread-onlyで開き、試験前後の全体SHA-256が一致した。
VFSの既存破損volume試験はBackend独自のチェックを継続しており、probeで代替していない。

CはASan/UBSan付きで実行し、新しいvolume moduleもRV32へcompileした。
Python232件、Zig Debug / ReleaseSafeも通過した。CIの既存Backend runnerから同じ試験が実行される。
remote CIの実行結果は今回の記録に含めない。

native firmwareへの最終link、常駐配置、stack admission、SD ownerの新sessionへの接続と実カードmountは未実施。
既存カードのformat、カードへの書込み、serial経由のfirmware差替えは今回行っていない。
前回の組込みFAT12 fixtureの3回の実機合格を、この新しいprobeの実機合格へ転用しない。
clean POR、writable FAT/exFAT、SQLite永続化・電断復旧も引き続き別のgateである。

```sh
python3 tools/check-fatfs-backend.py
python3 -m unittest discover -s tools -p '*test.py'
.tools/zig-0.17.0/zig build test
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
```
