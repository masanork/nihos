# 0047: boot時だけのSD検査コードをmapped Flashへ移す

2026-10-27。Status: Accepted（native opt-in SD qualification）。
[0046](0046-storage-endpoint-epochs-and-rebind.md)の画像では160 KiB primary SRAM内のheapが
49,664 Bで、48 KiB最低値に対する余裕は512 Bだった。

## 判断

`sdmmc_probe.run`はPSRAM mapping確認後・CPU1 release前に一度だけ実行する約10 KiBの関数である。
この関数だけを`.flash.text.sdboot`へ置き、既存の最初のmapped Flash pageのboot領域へ連結する。
loaderのmapped segment数、SRAM/stack境界、heap最低値は変更しない。
PSRAM probe/mappingと同じFlash windowだが、SD検査はmapping変更完了後に開始する。
Flashアクセスを止めた状態での実行やcache-off安全性を新たに保証するものではない。

runtime controller、SD read callback、512 B DMA staging、64 B descriptor、scheduler/IRQ hooks、
mutable kernel stateとtask/IRQ stackは内部SRAMに維持する。
PSRAMへ新たなkernel stateを移したり、IRQからFlash boot関数を呼んだりはしない。
SD boot関数が使うruntime helperは従来どおりSRAMに置く。

## 監査と実行確認

linkerにSD boot部分のstart/end symbolを加える。
image auditはこの範囲がboot領域末尾にあること、正確に`sdmmc_probe.run`一関数であること、
PSRAMの二つのboot関数との間に未監査のcode/大きなgapがないことを要求する。
任意のhelper/IRQ codeをFlashへ移すためのprefix許可にはしない。
DMA buffer/descriptorはサイズ・64 B alignment・内部SRAM全域包含を確認し、runtime callbackもresidentを要求する。
これらは構造検査でありcall graph全体やcache-off実行の証明ではない。

関数内で`auipc`を実行し、実際のPC sampleをReportへ保存する。
呼出し元はreturn後に`NIHOS_NATIVE_SDMMC_CODE`へ範囲・PC・完了statusを出す。
log checkerは画像のSD boot範囲とPC、completed=1、重複/欠落なしを要求する。
従来の`NIHOS_NATIVE_BOOT_CODE`はPSRAM probe/mapping完了の記録のまま。
SD bootへ配置を変えない過去画像では新recordを要求しない。

同じSD read-only/FS、SMP/PSRAM、取消し、endpoint世代切替、後続SQLite fixtureを再実行し、
固定画像を開始前/後verifyする。速度改善の主張は行わない。
