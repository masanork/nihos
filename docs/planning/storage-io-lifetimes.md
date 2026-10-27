# SDMMCとVFSのI/O寿命の接続

2026-10-27。native baseは`codex/tab5-memory-broker`の`b69b7c3`。
host VFS / FatFsは[PR #3](https://github.com/masanork/nihos/pull/3)、lease共通部は同PRの`542b3a3`から同一内容を取り込んだ。
この作業は`codex/vfs-native-lifetimes`の独立worktreeに置き、他セッションのconsole/launcherを変更しない。

## 接続した範囲

`nih_storage_read`と`nih_broker_sd_read`を、[ReadOwner](../../src/fs/sdmmc_owner.zig)経由で
[SDMMC controller](../../src/soc/esp32p4/sdmmc.zig)へ接続した。
固定1要求のledgerに登録してから発行し、実際の停止・descriptor・cache状態を確認してから要求を回収する。
既存の同期storage ownerがFS workspaceを保持し、brokerは従来どおりPSRAM destinationのparentをpinする。
DMAは永久予約の内部SRAM staging 512 Bとdescriptor 64 Bだけに向け、成功時にdestinationへコピーする。

ここで使うmount/file referenceはblock owner内のsessionを示す。
PR #3のpublic VFS root/file handle、principal、FatFs file recordの接続はまだ行っていない。
FatFsの実カードmountやSQLiteの永続化が完成したという記録ではない。

## 取消・抜去・再利用

[内部C hook](../../include/nihos_storage_io.h)は公開syscallではなく、trusted owner / IRQ側の通知専用とする。

- `nih_storage_io_active()`で発行中ticketを得る。0は発行なし。
- `nih_storage_io_stop(ticket, 1)`で取消を通知する。戻り値1は通知の受理であり、停止完了ではない。
- `nih_storage_io_removed()`は抜去をstickyに記録する。転送の間に通知されても次の発行を拒否する。
  card-detect GPIO/IRQ handlerの登録は未実装であり、この関数だけで物理抜去を自動検出するわけではない。

[resident mailbox](../../src/fs/io_stop.zig)はticketとreasonを単一32-bit atomicで更新する。
ticketは30 bitで循環させず、上限で発行を止める。古い取消・完了が後続ticketへ作用しない。
取消より抜去を優先する。completionの公開直前に通知windowをatomicで閉じ、先行した通知を成功結果へ変えない。
IRQ側ではFS、allocator、MMIO停止、descriptorやbufferの解放を行わない。

通常ownerはcommand待ち・data待ち・コピー直前で通知を確認する。
発行後の取消/抜去ではcontrollerをfaultedとし、新しいcard/controller sessionを用意するまで再発行しない。
leaseが返却可能になったことと、同じcontrollerで読取りを続けられることを区別する。
将来のVFS Backendはabort後のmountを失効させ、再mountを別世代として扱う。

## 停止の条件

1. peripheralとIDMACのinterrupt maskを0にし、controllerのinterrupt enableも落とす。
2. IDMAC enableを落とし、DMA resetのself-clearとIDMAC FSMのidleをbounded pollで確認する。
   DMA enable / internal DMA / bus modeとmaskもreadbackする。
3. raw statusをW1Cでdrainする。このdriverはpolling専用でSD IRQ handlerを登録しない。
4. descriptor baseを0にしてreadbackする。
5. stagingとdescriptorのcacheをinvalidateする。停止確認後に限りCPUが残存OWNを回収できる。
   descriptorをclear、writebackし、I/O fenceでCPUへの返却を終える。

いずれかが失敗すればleaseを残し、`prepare`や新しいreadによるstagingの上書きを拒否する。
このqualification fixtureには復旧ownerがないため、native側では`Quarantined`を通常のFS errorとして返さず、
失敗停止する。これによりclient/FS cleanupが保持中資源を回収する経路へ進まない。
将来のruntime serviceでは、隔離したcontroller、pin、mountを回収する専用復旧手順が別途必要である。

停止bitとFSMの意味は、固定した[ESP-IDF v5.4.4のSDMMC LL](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/sdmmc_ll.h)と
[rev1 register定義](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/register/hw_ver1/soc/sdmmc_struct.h)に照合した。
実機での停止・IRQ drain・cache整合の成功は、buildやhost MMIO modelだけからは判定しない。

## 検証と次の実機試験

[host / candidate記録](../measurements/2026-10-27-native-storage-io-host.json)にsourceとimageのhashを保存した。
Zig Debug / ReleaseSafe各198件、Python 173件、format / ZLint / ShellCheck、既存6構成のnative ELF監査が成功。
実controllerのcodeをMMIO modelで動かし、取消・抜去の各境界と、reset未完了、FSM非idle、descriptor切離し失敗、
cache返却失敗での隔離を検査した。判定器はfield欠落、非zeroの残存hardware state、古いimage、emulatorでの実機主張を拒否する。

新しいbroker opt-in imageは、既存qualificationの後に`NIHOS_NATIVE_IO_LIFETIMES`を実行する。
通常read→CMD17発行後の取消通知→完全な停止確認→新しいcard session→通常read→CMD17発行後の抜去通知→再発行拒否を調べる。
元のLBA 0 CRC、未公開のdestination、旧ticket拒否、reset/idle/mask/descriptorの最終値も照合する。
通知注入は実際のカード抜去ではなく、通知時点でsiliconの転送がまだ進行中だったという保証もない。

試験用Flash関数を明示的allowlistで監査する。追加の通常owner/SD処理はcache有効のmapped Flashに配置し、
notification hookとlease metadata、DMA staging / descriptorはresidentに保つ。
初期candidate `ad62703`は821,104 B。residentは105,792 B、112 KiB枠の余裕は8,896 B。
IRQからの全推移call graphやnative最悪時間/stack上限の証明ではない。

実機runner [qualify-storage-io.py](../../tools/qualify-storage-io.py)は、固定bundleの全指定hashを照合してから対象Tab5を確認する。
同じexclusive serial FDでFlash 16 MiB全体をprivateに退避し、partitionを照合、loader/appだけを書き換え、
3回のUSB reset起動と各PASS後10秒の監視を行う。成功/失敗いずれでも書換え範囲を復元し、元のFlash全体を照合する。
backupは秘密を含み得るため公開artifactには含めない。SDのformatや書込みは行わない。
runnerは構文、helpとartifact改変拒否をhostで検査した後、固定候補を実機で3回起動して全回合格した。
Flash退避と復元経路も実行し、16 MiB全体のdigest一致を確認した。
[実機記録](../measurements/2026-10-27-native-storage-io-physical.md)に通知、停止値、source/image hashと生ログの参照を保存した。

残るgateは、起動理由`0x01`を確認できるclean power-on、
silicon上の停止失敗・cache失敗の安全な注入、実FatFs BackendとVFS/RPCの接続である。
serialは解放済み。I/O寿命接続の起点はlocal commit `ad62703`で、後続の手操作・取得fixtureも独立branchに保持する。
他セッションのnative branchは変更していない。

## 手操作を伴う追加試験

`NIHOS_NATIVE_SD_REMOVAL=1`を、既存broker opt-in構成でだけ有効にできる。
通知注入を終えた後、全leaseの回収とDMA quiescenceを確認して新しいcard sessionを作る。
`NIHOS_SD_REMOVE_READY`を出してから、1-bit / 400 kHzでLBA 0を繰り返しreadする。
operatorが同じカードを抜き、readが失敗した後に、destination非公開、実hardwareの停止状態、
lease回収、旧ticket拒否、抜去latchによる新規発行拒否を記録する。

`NIHOS_SD_INSERT_READY`の後はoperatorが同じカードを戻す。
旧sessionがquiescentな場合だけSD電源とcontrollerを初期化し、identifyの成功後にmount世代を進める。
通知ticketの番号を維持して抜去latchを解除し、容量とLBA 0 CRCの一致を2回のreadで検査する。
容量とCRCはカードの唯一IDではなく、この試験の入力照合である。
各手操作の待ちは120秒で打ち切り、不完全な記録をPASSにしない。
接点断とDMA beatの前後を測るcard-detect入力はないため、実転送中の抜去を必ず捕捉する保証はない。

runnerはこの構成では1起動だけを取り、両READY markerをhostへ通知する。
read errorだけでは物理抜去と断定できないため、operatorの抜去・再挿入の確認記録を別途保存する。
firmwareの記録だけから`electrical_removal_operator_confirmed`をtrueにはしない。
operatorが同じmicroSDを抜き・戻す操作を行い、実カード試験に合格した。
[実抜去記録](../measurements/2026-10-27-sd-removal-physical.md)に、CMD17 timeout、停止後の状態、世代3→4と再読取りを保存した。

電源試験の最新fixtureは、手操作用imageとは別に、`SD_REMOVAL=0` / `COLD_CAPTURE=1`のbroker opt-in imageと
runnerの`--power-cycle`で実施する。
3回のUSB reset検証後に`NIHOS_POWER_CYCLE_READY`を出し、operatorの本体OFF→ONを待つ。
USB disconnectが起きた場合は同じportをexclusiveに開き直し、後続Flashアクセス前にchip/MACを再確認する。
新たなUSB resetを指示せず、最初にROM APIから保存したreset reasonとhost ACK後の全ログを取得する。
power-on (`0x1`)の1起動を要求し、USB reset、watchdog、複数bootの混在をcold bootの成功に含めない。
ROM headerが失われた場合でもimageに結び付いた機器側recordは必要で、両方が欠けた記録は拒否する。
FDを開き直した場合は、その回数と「同一FDを維持したか」を分けて記録する。
電源OFF中に接続が戻らない場合は復元を完了できないため、private backupと失敗ログを保持し、電源復帰後に復元を完了する。

追加経路OFFの通常設定は、commit `b21e114`の固定imageで実機3回のUSB reset起動にも合格した。
[通常設定の回帰結果](../measurements/2026-10-27-sd-manual-normal-physical.json)に生ログhashと復元照合を保存した。
これは手操作用imageの実抜去試験やcold bootの合格ではない。

[公式のTab5操作説明](https://docs.m5stack.com/ja/core/Tab5)も照合した。
公式には電源キーのダブルクリックでshutdown、単押しで起動と記載され、直接給電を切った場合は5秒以上空けるとしている。
このnative fixtureでボタンによるshutdown処理は検証していないため、操作方法だけから電源断を成立したと見なさず、
実際の給電構成、operatorの操作記録、ROMのreset reasonを併せて確認する。

電源キーの操作後、USB消失と復帰、および復帰後の全workload成功は確認した。
ただし機器側に保存したreset reasonは`0x07`であり、clean power-on gateは合格にしていない。
[電源試験の記録と未解決点](../measurements/2026-10-27-sd-cold-power-inconclusive.md)に取得経路の修正と全失敗試行を残した。
起動待ち前へのTG0 MWDT停止の移動だけでは`0x07`が解消せず、原因は未確定である。
最新候補`c6e3190`は821,904 B、resident 105,920 B、112 KiB枠の余裕8,768 Bである。
USBとバッテリーを両方外す試験は、operatorが実施困難なため未実施のまま残す。

## 次回採取用のreset snapshot（host検証まで）

`COLD_CAPTURE=1`の新規buildは`capture_format=2`をmanifestに保存する。
[reset_capture.zig](../../src/soc/esp32p4/reset_capture.zig)で、nativeの`watchdogOff`と
`prepareTimers`より前にreset cause word、LP / HP0 / HP1の理由とflag、ROM保存PC 2語、
TG0 / TG1のclock gateとWDT config0を読み取る。reset flagのclearやclock操作は行わず、
clockが無効なtimerは読み出さず、`wdt_valid`とゼロ値を組にする。
`wdt_valid=0`のゼロ値を「WDT停止済み」の証拠にはしない。

アドレスは固定SDK v5.4.4のESP32-P4 hw_ver1 register定義と`esp32p4.rom.ld`へ照合した。
ROM data alias `g_saved_pc` (`0x4ff3fff8`, 8 B)と追加source hashもimage監査の対象にする。
保存PCはraw値で、有効性や直前resetとの対応は保証されない。
採取前にはROM、loader、native assembly CRTが既に走っているため、
これだけでROM / loader内部の停止箇所を確定したことにはならない。

ログ検証はformat 1の既存実機証跡とformat 2をmanifestで区別し、
format 2の理由・flag・WDT validとraw wordの不一致、欠落、重複、未知formatを拒否する。
clean power-onは引き続きHP CPU0理由`0x01`とACKを要求し、`0x07`を合格へ変更しない。
[host検証記録](../measurements/2026-10-27-native-reset-snapshot-host.json)には新候補のhashと監査を保存した。
新snapshotは実機未検証で、この追加作業ではserial接続・Flash書込み・電源操作を行っていない。
