# ページ化indexと容量に依存しないmountのホスト検証

2026-10-27。`codex/store-crash-model`、実装commit `b751f89`。
[実file backend](2026-10-27-store-file-backend.md)に、ページ化したCOW indexと毎commitのcheckpointを接続した。
16 GiBの疎fileで、4 GiBを超えるoffsetへの保存、別processでの再open、metadataだけのmountを確認した。
実SDへの書込み、Tab5での実行、物理電源断の検証は含まない。

## 実装した境界

[checkpoint_model.zig](../../src/storage/checkpoint_model.zig)は、交互に更新する2枚の4 KiB rootと、4 KiBのimmutable leafを使う。
各leafは126 keyを持ち、root内の128参照で16,128 keyの範囲を表現する。
root／leafにはCRCと世代・geometry・参照先の検査があり、不完全なcheckpointは候補から除外する。
I/Oエラーは旧世代へのfallbackで隠さず、instanceをfault状態にする。

commitは「payloadとleafを書込む → sync → rootを書込む → sync → ack」の順に行う。
復旧時は両rootのmetadataだけを読み、完全な候補のうち最新世代を採用する。
payloadのCRCは読取り時に検査し、破損したpayloadを返さずfaultにする。
後続logはまだなく、tail replayは0 B。毎commitでcheckpointする方式の検証であり、log全体の回復実装ではない。

媒体容量・byte offset・payload長は`u64`とし、buffer長だけを`usize`とした。
既存file backendと故障注入backendも、媒体offsetを`u64`で受ける。
[RV32 probe](../../tools/probes/checkpoint_rv32.zig)は16 GiB構成でformat／recover／put／remove／commit／readをコンパイルする。
接続先は未実装の外部media関数であり、SD driverとの接続や実行結果を示すものではない。

## RAMとmount読取り量

|項目|結果・上限|
|---|---:|
|ホストarm64のstore状態|8,280 B|
|RV32のstore状態|8,272 B|
|1 GiBと16 GiBでの状態サイズ|同一|
|root参照数|128 leaf|
|mount読取りの最大値|1,056,768 B = (2 + 2 × 128) × 4,096|
|tail replay|0 B|

状態サイズにはcurrent／stagedのroot参照と4 KiB scratchを含む。call stack、backend、OS file cacheは含まない。
store自身はheapを確保しないが、これだけで総RAM peakや実機のstack余裕を測定したことにはならない。
実験用storeの2 MiB envelopeやnative memory profileは変更していない。

疎file試験の通常更新後は3 leafを使い、両rootを含め32,768 Bでmountした。
次に128 leafをすべて作り、両rootが128 leafを参照する状態で、上限の1,056,768 Bを実際に読んだ。
mount中はmetadata領域の外を読むと失敗するwrapperを使い、payload走査がないことも検査した。
媒体を埋めた際のlatencyや5秒以内のmountを確認したわけではない。

## 別processと故障注入

[runner](../../tools/checkpoint_probe.py)は16 GiB fileをexclusive createし、疎領域を維持して先頭rootだけを初期化する。
payloadは末尾256 KiBの領域に置き、71,681 Bのobjectを含む旧／新世代を別processから全byte照合した。
更新後の先頭payload byte offsetは17,179,684,864。32 bitを超える位置へのpositional I/Oを通した。
これは64 bit offsetの検査用geometryで、16 GiB分のdataや利用率を検証するworkloadではない。

11 processで、通常再open、payload破損の遅延検出、全128 leafのmount、保存rangeからの疎file再構築を確認した。
意図的に破損させたpayloadではmetadata mountが成功し、readが`Corrupt`を返すことを確認してから元のbyteを戻した。
archiveには全16 GiBをcopyせず、metadataと末尾payloadのrange・offset・hashを保存する。
省略領域は0のholeで、再構築した別imageも全indexを検証した。

memory-backed故障注入は、130個の書込み／sync event、3種類の背景writeback、2種類のflush順序、6種類のsector prefixで
**4,680条件**を検査した。復旧後は旧世代または完全な新世代だけを許容し、6件の正常ack後は必ず新世代を回復した。
これはその故障モデル内の結果であり、SDの原子性や電源断耐性の証明ではない。

[negative control](../../tools/checkpoint_negative_control.py)は、copyしたsourceから最初のsyncだけを除く。
event数とcase数の固定値検査だけをcopy側で外し、復旧状態の検査は残す。
event 96、prefix 512、背景writebackなし、昇順flushで、世代3のmetadataを復旧した後のpayload読取りが`Corrupt`となった。
同期順序の誤りを、単なるevent数の相違ではなく公開dataの不整合として検出できた。

Zig Debug／ReleaseSafe各209件、Python 168件、format／ZLint／ShellCheck、RV32のbrokerとcheckpoint compile、
6種類の既存native ELF link／配置監査が合格した。
既存file backendの6ケース・22 process・3 SIGKILLも再実行し、元の4,212条件の公開モデルは両build modeで通した。

## 残っている制約と次の実装

まだGCもmetadata再利用もなく、put／removeごとに4 KiB leafを1枚追加する。
defaultのindex poolは4,096 pageなので、空から最大4,096回の変更でmetadataが尽きる。
16,128は表現可能なkey範囲であり、default poolでそれだけのobjectを作れるという意味ではない。
疎file probeのpoolは256 page、payloadは64 pageに制限しており、ほぼ満杯の媒体を試していない。

readのたびにobject全体のCRCを検査するため、小さな部分readを繰り返す用途には非効率である。
次は部分read用のrange checksumと、未参照leaf／payloadを回収するcleanerを検討する。
reader pin、clean reserve、checkpoint頻度の低減とbounded tail replay、streaming書込みも必要となる。
SQLiteの永続VFS・PERSIST/FULL・WAL、SD／NORへの接続は未実装のまま。
native起動経路や、実機待ちのcold-Flash候補は変更していない。

## 再現と保存

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
sh tools/run-checkpoint-test.sh
python3 tools/checkpoint_negative_control.py .tools/zig-0.17.0/zig
sh tools/run-store-file-test.sh
sh tools/run-static-analysis.sh
```

process試験とnegative controlは毎回新しいdirectoryへ保存する。
[構造化結果](2026-10-27-store-checkpoint.json)と
[source・binary・range・ログのarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-checkpoint-host)を残した。
manifestを除く29 fileのSHA-256を再照合した。別archiveに保持しているcold-Flash候補も55 fileのhashが一致し、変更していないことを確認した。
