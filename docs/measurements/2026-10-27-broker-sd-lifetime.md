# 強制終了をまたぐbroker parentと実SD読取り

2026-10-27。`codex/tab5-memory-broker`、最初の実装 `c30269d`、タイマー寿命の修正 `5ee3a19`。
[正常EXITと排他的handoff](2026-10-27-broker-native-handoff.md)を拡張するversion 2のopt-in試験。
ホスト検査と配置監査に加え、修正版 `5ee3a19` の実機3回のUSBリセット起動に合格した。
後続の[検証コードのFlash配置候補](2026-10-27-native-cold-flash.md)ではresident枠の余裕を回復したが、実機確認は未実施。

## 実装した順序

1. 前段のSMP／SD／storage／SQLite試験を完了し、両CPUの旧heapを失効させる。
2. 従来どおり、CPU1 clientを正常EXIT→回収→再利用する試験を2回行う。
3. 3世代目のclientが4 KiB parentを取得し、SD読取り要求を送って待機する。
4. CPU0がparentをpinし、LBA 0の512 Bを実ドライバで読む。
5. 前段が停止済みのTG1 timerを単独で取得し直す。1 MHz設定とcounter有効を確認し、DMAを設定して実CMD17のregister writeとI/O fenceを行った直後に、通常contextのgateがCPU1へ終了要求を出す。
6. CPU1のbootstrapが待機中clientをexit code -97で強制終了する。CPU0はその停止通知を受けてから完了処理へ進む。
7. ドライバが応答／data-overを確認し、DMAを停止、descriptorとstagingのcacheを同期し、保持中parentへコピーする。その後TG1 timerを停止して返す。
8. pinが残る間のfree拒否とsector CRCを確認し、終了済みclientへの応答を破棄する。
9. ownerをcloseし、pinによる回収待ちを確認してからborrower完了を通知する。parentとownerの回収後にだけreapを許可する。
10. 同じslotを次世代で再利用し、強制終了したclientのidentityとlease tokenを拒否する。最後に全parentとguardを照合する。

IRQ側はresidentの終了要求・通知だけを扱う。SD gateの待機はCPU0の通常driver contextでFlash上から行い、IRQ stackでは実行しない。
既存のSD controllerをstorage owner退役後に単独利用し、SDへの書込みは行わない。
DMA先は既存のresident SRAM staging 512 Bであり、PSRAMへの直接DMAではない。
pinはstagingからPSRAMへのコピーを含むborrower全体の寿命を保持する。

CMD17発行後からsoftware completionまでの間にtaskを停止する試験である。
停止時にSDハードウェアがまだ転送中だったと保証するものではない。
controllerを途中でabortせず、正常なI/O完了を待つ。実DMA abortやDMA故障時の再利用可否は別のgateとする。
gateやreadで失敗した場合は試験を停止し、pinを時間切れだけで解除しない。

## メモリと配置

broker payloadは内部208 KiB／外部30 MiB、metadataは16 KiB予約中12,912 Bを維持した。
network classの内部64 KiBを保持したまま、clientの内部8 KiBと外部parentを扱う。
最低空きのpolicyは内部64 KiB／外部8.5 MiBのままである。

今回の候補は低位resident 114,688 B（112 KiB）で、旧heap先頭がちょうど`0x4ff1c000`となる。
旧heap 48 KiBとresident 112 KiBは予算どおりだが、residentの追加余裕は0 Bになった。
今後resident処理を増やす場合はFlash配置やmetadata配置を見直す。heap floorを下げて通す変更はしていない。
frame／IRQを含むstack余裕は別途実測対象とする。

## ホスト検証

Zig Debug／ReleaseSafe各184件、Python 158件、format／ZLint／ShellCheck、
RV32 broker compile、既存6種類のnative ELF linkと配置監査に合格した。
実機候補は保持済みloader ELF／cache設定でも配置監査を通した。

判定器は強制終了・pin保持・完了順序・応答破棄・CRC・slot世代が欠けた証跡を拒否する。
version 1の正常EXIT記録も判定でき、保存済み実機3回の生ログを現判定器で再検証した。
version 1のログをversion 2の試験として扱うことは拒否する。

```sh
NIHOS_NATIVE_MEMORY_BROKER=1 NIHOS_NATIVE_HIGH_SRAM=1 \
NIHOS_NATIVE_SDMMC=1 NIHOS_NATIVE_SDMMC_PROFILE=2 \
NIHOS_NATIVE_STORAGE=1 NIHOS_NATIVE_STORAGE_SERVICE=1 \
sh tools/build-native.sh device sqlite
```

version 2は`STORAGE_SERVICE=1`も必須とする。既定値は引き続きbroker無効。
公開syscall／driver ABI、起動時からの全面移行、16 task化、無線・IME・SQL・GCの同時負荷は未実施。

## 実機で切り分けたタイマーの寿命

attempt 1〜4は最終PASSに到達せず、試験を不合格として保存した。
追加した段階ログから、正常EXITの2世代は通り、3世代目のSD読取り呼出しで止まることを確認した。
原因は`storage_runtime.finish`がTG1 counterを停止する一方、retained SD controllerが同じtimerを保持していたことだった。
後続のdriver delayは停止済みcounterが進むのを待ち、bounded loopの上限でtask invariant違反になった。
SD発行後の終了通知まで到達した失敗とは扱わない。

`5ee3a19`でCPU0がTG1を単独で取得し直し、1 MHzの動作を検査してからI/Oを開始するよう修正した。
DMA停止・cache同期・PSRAMコピーの成功後にtimerを停止し、取得と返却の両方を証跡へ追加した。
メモリ領域のhandoffだけでは、driverが保持する周辺資源の寿命を引き継げないことを示した実機不具合である。

## 実機結果

Tab5 ESP32-P4 rev1.3、Flash 16 MiB、PSRAM 32 MiB、MAC `e8:f6:0a:e2:e8:9c`。
appは814,416 B、SHA-256 `35b212ec5635df168dff721fed079bd731f730c9f1ed38e6632cd9749a37dbb0`。
ELF SHA-256 `83dc006adcb0acc4fdc2a9baaaa07a6e9c07d30277b8fdf70e93f81a1e1e25e5`。
保持済みloader／cache設定を指定した配置監査も通した。

他の利用者がserialを解放した後にexclusive FDを取得し、同じFDでpartition tableの事前照合、
ESP-IDF参照の再取得、候補書込み、全3起動、最終Flash照合を行った。
書込みはloader `0x2000` とapp `0x10000` のみ。partition table `0x8000` は変更していない。
各起動とも約45.5〜45.7秒で試験とPASS後10秒の監視を完了した。

|確認項目|全3回の結果|
|---|---|
|client世代|slot 1、generation 5→6→7（強制終了）→8|
|要求／応答|16／15、終了済みclientへの応答破棄1|
|EXIT／reap|4／4、うち強制終了1|
|pinによる回収待ち／borrower完了|4／4|
|古いidentity／lease拒否|3／2|
|実SD read|LBA 0、512 B、CRC `0x9022e83d`、boot時の読取りと一致|
|SD command発行／完了|各1、software completionはtask停止後|
|終了後のpin保持|freeをBusyで拒否、コピー完了前には解放しない|
|TG1 clock取得／返却|各1、counterの有効／停止を照合|
|内部／外部の全量回復|212,992 B／31,457,280 B|
|guard|16,384 B維持|
|client stack観測|停止後のpaint scanで448 B|

既存の300 round SMP、64 IPI、SDMMC全3transportと各1,024箇所の分散読取り、
storageの強制終了・再bind、SQLite 2 session／26 statementも全回合格した。
SD分散digestは `0x524262a3`。新しく実行したESP-IDF参照と各起動のSD／file API結果を比較し、
計6件が一致した。追加broker readのCRCも同じLBA 0の結果と一致する。
SQLiteのstack観測は6,552 B、storage owner／clientは3,216／1,920 Bだった。
いずれも観測した経路の値で、未実施の同時負荷や最大IRQ stackを保証しない。

試験前後ともloader／partition table／appのFlash照合に合格した。
USB RTS resetで電源を保持しており、OFF→ON試験ではない。完了後にserial FDを解放した。
インストール内容はこの時点の記録であり、他セッションの後続書込みまで固定するものではない。

[構造化結果](2026-10-27-broker-sd-lifetime.json)に候補hash、失敗4件、成功3回の計数、比較と残るgateを記録した。
[source・全5候補・生ログ・照合結果のarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-tab5-broker-sd-lifetime-qualification)
には全ファイルのSHA-256一覧を付け、保存直後に全件を再照合した。
