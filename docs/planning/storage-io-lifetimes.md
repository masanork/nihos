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
candidateは821,104 B。residentは105,792 B、112 KiB枠の余裕は8,896 B。
IRQからの全推移call graphやnative最悪時間/stack上限の証明ではない。

実機runner [qualify-storage-io.py](../../tools/qualify-storage-io.py)は、固定bundleの全指定hashを照合してから対象Tab5を確認する。
同じexclusive serial FDでFlash 16 MiB全体をprivateに退避し、partitionを照合、loader/appだけを書き換え、
3回のUSB reset起動と各PASS後10秒の監視を行う。成功/失敗いずれでも書換え範囲を復元し、元のFlash全体を照合する。
backupは秘密を含み得るため公開artifactには含めない。SDのformatや書込みは行わない。
runnerは構文、helpとartifact改変拒否をhostで検査済み。実機への書込み・runnerの復元経路は未実施。

残るgateは、共有Tab5の利用調整後のexact candidate試験、電気的な抜去/再挿入、電源OFF→ON、
silicon上の停止失敗・cache失敗の安全な注入、実FatFs BackendとVFS/RPCの接続である。
現時点ではserial resetやFlash書込みを行っていない。native側の変更はlocal commitとして保持し、実機未確認のまま公開しない。
