# Native memory brokerへの排他的handoff

2026-10-27。`codex/tab5-memory-broker`。
[共通broker](2026-10-27-memory-broker.md)をnative schedulerへ接続したopt-in試験。
実装commit `6712750` の候補で、ホスト検査と実機3回のUSBリセット起動を通した。
これは既存試験終了後のhandoffの検証である。
後続の[version 2の実SD読取りと強制終了](2026-10-27-broker-sd-lifetime.md)で借用寿命の検証を進めた。

## 移譲と配置

既存のSMP・SDMMC・storage・SQLite試験を完了し、CPU1の利用終了通知を受けてから旧allocatorを失効させる。
両CPUのlive allocationとresource ledgerが空であることを検査し、内部／外部heapをterminal stateへ移す。
旧内部alloc、旧外部prepare/alloc、旧pool openの4経路で拒否を確認してからbrokerを初期化する。

|領域|開始–終了|用途|
|---|---|---|
|低位SRAM|`0x4ff1c000..0x4ff28000`|48 KiB payload|
|高位SRAM|`0x4ff73000..0x4ff77000`|16 KiB metadata予約、実使用12,912 B|
|高位SRAM|`0x4ff77000..0x4ff9f000`|160 KiB payload|
|PSRAM|`0x48200000..0x4a000000`|30 MiB payload|
|PSRAM boot予約内|`0x48008000..0x48010000`|固定長RPCと試験状態、32 KiB予約|

最低空きはSRAM 64 KiB、PSRAM 8.5 MiB。broker metadataは既存224 KiB heap予算から16 KiBを使う。
network classでSRAM 64 KiBを保持しながら、CPU1 clientの内部8 KiBとPSRAMを割り当てる。
VM classでは4／8 MiBを各同量のbackingで取得し、全wordの初期消去と書込み・読出しを検査する。
通信・IMEというclass名は予算検査用で、今回その機能を動かすものではない。

## 実タスクの終了と回収

CPU1の実kernel taskから固定長SPSC要求を送り、CPU0がbrokerを直列操作する。
1回目は8 KiB、2回目は2 MiBの外部parentを借りる。CPU0側の非同期利用をpinで保持し、
clientからのfreeをBusyで拒否する。実際のEXIT通知を受けてcloseし、pinが残る間は回収を待つ。
CPU0が全payloadを検査して完了通知を出し、parentとownerを回収した後にschedulerがreapする。
同じtask slotを次世代で再利用し、古いtask identityとlease tokenを拒否する。
全試験後にnetwork parentも解放し、内部208 KiB／外部30 MiBの全量回復と16 KiB guardを検査する。

IRQ hookはresident SRAMのatomic通知だけとし、broker処理は既存の監査済みFlash領域で行う。
RPC wakeupはbootstrap polling経由のevent通知。これは信頼されたnative fixtureで、公開syscall ABIやDMA実装ではない。

## 候補と検証

候補appは810,896 B、SHA-256 `936efe273ee4eb07517e23de4c5f02ecb04cf0dda2c55790e27f172a0e4ce84c`。
ELF SHA-256 `4a5c94738d2ae1a19a5e2936f514d91de3147d1cd91f7bd9f0ff56fc9ecc3c73`。
低位residentは114,048 B、旧heapは49,792 B。移譲後の低位payload 48 KiBに対する余裕は640 B。
保持済みloader ELF／cache設定を指定した配置監査も合格した。

Zig Debug／ReleaseSafe各184件、Python 155件、format／ZLint／ShellCheck、
RV32 broker契約compile、既存6種類のnative ELF linkと配置監査に合格した。
追加した8件の判定器試験は欠落・重複・不正な回収数・floor・slot世代・配置・実機証跡種別を拒否する。

```sh
NIHOS_NATIVE_MEMORY_BROKER=1 NIHOS_NATIVE_HIGH_SRAM=1 \
NIHOS_NATIVE_SDMMC=1 NIHOS_NATIVE_SDMMC_PROFILE=2 \
NIHOS_NATIVE_STORAGE=1 NIHOS_NATIVE_STORAGE_SERVICE=1 \
sh tools/build-native.sh device sqlite
```

`NIHOS_NATIVE_MEMORY_BROKER=0`が既定値。device／sqlite／HIGH_SRAM以外の組合せは拒否する。
既存試験後の実験的移譲であり、起動時からの全面置換、16 task化、強制killと実DMA abort、
Wi-Fi／BLE／IME／SQL／GCの同時負荷は未実施。今回の正常EXITと模擬借用完了とは分けて検証する。

## 実機結果

Tab5 ESP32-P4 rev1.3、Flash 16 MiB、PSRAM 32 MiB、MAC `e8:f6:0a:e2:e8:9c`。
他のserial利用者がいないことを確認してexclusive FDを取得し、同じFDを保持したまま
partition tableの事前照合、ESP-IDF参照の実行、候補書込み、全3起動、試験後のFlash照合を行った。
書込みはloader `0x2000` とapp `0x10000` のみ。partition table `0x8000` は変更せず、前後とも一致した。
loader SHA-256は `5f1565c93f3bea4fe29cd9f26f4e66343e4fdd26cea31bb6ec9a5966a84f1355`。

3回とも約45.6秒で試験とPASS後10秒の監視を完了した。全回で次を確認した。

- 旧API拒否4経路、VM 4／8 MiBの要求量と課金量の一致。
- client identity `0x00050001` → `0x00060001`。slot 1を世代5→6で再利用。
- RPC 9要求／9応答、拒否5件。実EXIT 2回、reap 2回。
- pinによる回収待ち2回と、borrower完了2回。古いidentity拒否2件、古いlease拒否1件。
- 内部212,992 B／外部31,457,280 Bを全量回収。16,384 Bのguard維持。
- client stackのpaint観測400 B。callee／IRQを含む一般的な最大stack保証ではない。

既存の300 round SMP、64 IPI、SDMMC 1-bit 400 kHz → 4-bit 400 kHz → 4-bit 20 MHz、
各transportの1,024箇所の分散読取り、storageの強制終了・再bind、SQLite 2 session／26 statementも合格した。
SD全3transportの分散digestは `0x524262a3`。新しく実行したESP-IDF参照と、各起動のSD／file API結果を比較し、
計6件の比較が一致した。storageの強制終了は既存経路の回帰試験であり、新brokerの強制終了試験とは区別する。

試験前後ともloader／partition table／appのFlash照合に合格した。
全回ともUSB RTSによるresetで電源を保持しており、OFF→ON試験ではない。
完了後にserial FDを解放した。インストール済み内容はこの時点の記録である。

[構造化結果](2026-10-27-broker-native-handoff.json)にhash、各回の計数、比較結果と残るgateを記録した。
[source・候補image・生ログ・照合結果のarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-tab5-broker-handoff-qualification)
には全ファイルのSHA-256一覧を付け、保存直後に全件を再照合した。
