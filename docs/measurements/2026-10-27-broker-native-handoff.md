# Native memory brokerへの排他的handoff

2026-10-27。`codex/tab5-memory-broker`。
[共通broker](2026-10-27-memory-broker.md)をnative schedulerへ接続したopt-in試験。
現時点ではホスト検査と実機候補の配置監査まで合格。実機結果は後続の記録で区別する。

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
