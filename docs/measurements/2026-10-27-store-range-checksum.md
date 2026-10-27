# 部分readの範囲checksumとホスト検証

2026-10-27。`codex/store-crash-model`、実装`13008fc`、fixture名の補正を含むsource snapshot `fc338ce`。
[ページ化checkpoint](2026-10-27-store-checkpoint.md)の通常readでobject全体を走査する処理を置き換えた。
16 GiB疎fileと別processで、71,681 B objectの1 byteを12,288 Bのbackend read要求で取得した。
4,157,441 B objectでも1 byteの取得は12,288 Bに収まり、object長に比例する走査をしないことを確認した。
実SDへの書込み、Tab5実行、実電源断、SQLite永続VFSとの接続は含まない。

## 形式と書込み順序

[checkpoint_model.zig](../../src/storage/checkpoint_model.zig)の実験用形式をversion 2に更新した。
payload本体は4 KiB単位の連続領域のままとし、その後ろにページ別CRCのsidecarを置く。
各sidecar pageは、32 Bのheader、1,015個のCRC32、末尾4 Bのpage CRCを持つ。
headerのmagic／version／payload先頭page／object長／table番号を検査し、別extentや別tableへの取り違えを拒否する。
最終payload pageの0埋めを含め、4 KiB全体のCRCを検査する。

putのadmissionはpayloadとsidecarの両方のpage数を含む。
sidecar作成には既存の4 KiB scratchを使い、最後にstaged leafを再読込みして同じleafの他keyを保つ。
checksum用に媒体容量に比例するRAM配列を追加していない。
commitはpayload・sidecar・leafのsync後にrootを公開し、rootのsync成功後だけackする。

sidecarは1,015 payload pageごとに4 KiBを使い、大きなobjectでの追加容量は約0.1%へ近づく。
16 MiB objectでは20 KiB、1 GiB objectでは1,060,864 Bの追加となる。
小さいobjectにも最低4 KiBのsidecarを使うため、多数の小fileの効率は目的にしていない。
既存の16,128 key範囲、index poolと毎commitのcheckpoint方式は変更していない。

## readと全体検査の契約

readはkeyのleafを取得し、要求範囲が触れるchecksum表とpayload pageだけを読む。
連続read内では同じchecksum表を使い回す。検証したbufferから直接copyし、検証後にpayloadを再readしない。
EOF／空bufferならmetadata確認後に0を返し、payloadは読まない。

通常readは触れていないpageの完全性まで保証しない。
追加した`verify(key)`は全payloadとsidecarを検査し、leafに保持したobject全体のCRCとも比較する。
バックグラウンドscrubの実行方針やscheduleはまだ実装していない。

破損またはI/Oエラーはinstanceをfaultにし、進行中のtransactionを解除する。
不正なpageのbyteをdestinationへcopyしない。
複数pageのreadで後続pageが失敗した場合、destinationの先頭には検証済みpageの部分が残り得る。
返り値はエラーなので、そのbufferを成功したreadとして扱ってはならない。

version 1を自動変換・formatしない。checksumが有効な旧形式rootも`Corrupt`として拒否し、書込みを行わないことをテストした。
この形式はホスト実験用で、実機の保持候補や利用者の媒体を移行したものではない。

## 測定結果

以下はbackendへのread要求byte数であり、OS cacheを経た物理disk I/OやSD転送時間の測定ではない。
mountとprobeの結果表示用metadata readは除く。read間のcacheは追加していない。

|object・操作|read要求量|内訳|
|---|---:|---|
|71,681 Bから1 byte|12,288 B|leaf + checksum表 + payload各1 page|
|同object、4 KiB境界の2 byte|16,384 B|leaf + checksum表 + payload 2 page|
|同objectの明示的な全体検査|81,920 B|leaf + checksum表 + payload 18 page|
|4,157,441 Bから1 byte|12,288 B|leaf + checksum表 + payload各1 page|
|同object、checksum表の境界の2 byte|20,480 B|leaf + checksum表 2 page + payload 2 page|

旧方式の計算上の1 byte readは「leaf 4,096 B + object全体 + 要求1 B」だった。
部分readの費用をobject長から切り離したが、4 KiBごとのCRC計算と最低3 pageのcold readは残る。
将来の512 KiB map cacheやpayload cacheはこの測定に含まない。

store状態はarm64で8,280 B、RV32のcompile結果で8,272 Bと前回から変わらない。
read／verifyの一時bufferは4 KiBになった。状態サイズにcall stack・backend・OS file cacheは含まれず、実機の総RAM peakは未測定。
mountはpayload／sidecarを読まず、全128 leafを両rootが参照する状態で上限1,056,768 Bを再確認した。

## 試験と保存

[6件の追加Zig test](../../src/storage/range_checksum_test.zig)は、部分readの上限、EOF・空buffer、同じleafの隣key、
未読範囲の破損、checksum表のCRCとidentity、I/O fault、境界readのbuffer、複数table、容量admission、旧形式拒否を検査する。
CRCが正しいままheaderを変えたsidecarも拒否し、page CRCだけの検査で済ませていない。

checksum表の書込みを含む162 eventについて、3種の背景writeback × 2種のflush順 × 6種のsector prefixで
5,832条件の中断を試した。復旧は旧／新の完全な世代に限られ、6件の正常ack後は新世代を回復した。
最初のsyncを外すnegative controlは、event 112、prefix 512、背景writebackなし、昇順flushで
世代3のmetadata復旧後に`Corrupt`となり、誤った公開順序を検出した。

16 GiB疎fileの6ケース・17 processも成功した。
未読pageを破損させたまま別processから正常pageを読めること、その破損pageへのreadと`verify`が失敗することを確認した。
source・probe binary・2世代分のmetadata／payload range・再構築結果・失敗させたnegative controlを保存した。
全16 GiBの通常copyはせず、範囲外は0のholeとして復元する。

Zig Debug／ReleaseSafe各215件、Python 168件、format／ZLint／ShellCheck、RV32のbrokerとcheckpoint compile、
6種類の既存native ELF link／配置監査が合格した。元のCOWモデル4,212条件も両build modeで通った。
native起動経路と、保持しているcold-Flash実機候補は変更していない。

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
sh tools/run-checkpoint-test.sh
python3 tools/checkpoint_negative_control.py .tools/zig-0.17.0/zig
sh tools/run-static-analysis.sh
```

[構造化結果](2026-10-27-store-range-checksum.json)と
[archive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-range-checksum-host)を保存した。
manifestを除く27 fileのSHA-256を再照合し、保持中のcold-Flash候補も55 fileのhashが一致した。
次のgateはreader pin・clean reserveを含むGCと、index領域の安全な再利用。
defaultのindex poolは依然4,096回のput／removeで尽きる。
streaming書込み、部分更新、bounded tail replay、SD／NOR adapter、SQLiteのPERSIST/FULLとWALは未実装のまま。
