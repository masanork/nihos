# VFS通知とkernel待機のhost結合、およびcall-stack inventory

2026-10-28。base `b9dc0a2`。前回のnative link候補に対し、待機・通知・停止の競合順序を
実装のScheduler / task_control / VFS RPCと組み合わせてhostで検査した。
実機の命令実行、MMIO、IPI配送、weak-memory、DMAの試験ではない。
今回もserial接続、Flash書込み、電源操作は行っていない。
[結果JSON](2026-10-28-fatfs-wakeup-host.json)にsource/imageの同一性と残るgateを保存した。

## 検証した競合

[resident latch](../../src/kernel/event_latch.zig)をnative FSDの2個の通知wordへ適用し、
hostとnativeが同じ32-bit release/acquire操作を使うようにした。各wordは4 Bで、配置・予算は変わらない。
queueをpublishした後にlatchを立て、hardware doorbellを鳴らす。
IRQ tailはdoorbellをackした後にlatchをexchangeし、kernelのnotifyへ渡す。
queueが仕事を保持するので、複数通知のcoalesceや遅延した空通知は許容する。

[host試験](../../src/fs/vfs_wakeup_test.zig)で次を確認した。

- request / reply / response creditごとに、publish→latch→IRQとcheck→waitの全10通り、計30通りを検査。
  IRQがwait登録より前でも後でも仕事へ戻り、deferred event resultは一度だけ消費する。
- IRQ→kernel notifyを省く負例は、3方向ともcheck→wait間で待機が解除されない。
- 2 requestの通知をcoalesceしても、1回のwakeで実RPCが両方を処理する。
- read callback内でSchedulerのterminateを呼び、running / waiting / 通知済みreadyの3状態から停止する。
  その後だけRPCへ停止通知し、未実行requestとactive replyを捨てる。
  slot再利用後はkernel世代とRPC epoch/fileが更新され、旧通知で停止taskが復活しない。
- stickyなhardware pending bitのモデルでは、producerのlatch/bellとIRQのack/exchangeの全6通りが成功する。
  順序をexchange→ackへ逆転した負例では1通りが通知を失う。

最後の試験のhardware bitはhostモデルである。現native IRQ tailのack→pendingという順序を前提としており、
実MMIOのorderingや配送の合格を主張しない。read backendも小さなfakeで、実FatFsは前回の別試験である。
5件の新しいZig testを追加し、Debug / ReleaseSafe各243件が成功した。

## 総stackの未確認部分を判定器へ残す

[call-stack inventory](../../tools/check-native-call-stack.py)を追加した。
最終ELFのfunction extents / alias / static frame metadataと、GNU objdumpの命令を結び付ける。
直接call・tail transfer・function間branchを追い、間接transfer、ROM/assembly境界、未測定frame、
再帰、disassembly欠落を明示する。tailはcaller分を残して保守的に加算する。

最終候補で入口からの既知frameの構造上の合算は2,944 B、FSD部分は2,928 B、client部分は224 Bだった。
これは実行可能な全経路の上限・下限でも、4 KiB総stackの合格でもない。
入口全体はframe未測定12関数と未解決transferを含む12関数、FSDだけでは11関数と9関数、
clientだけでは8関数と4関数が残る。
memcpy / memmove / 除算helper、stack paint、fatal logging、task-call assembly、ROM putc、
disk callback、cancel callback、jump table等をゼロcostと仮定しない。

`--require-closed`はこの候補をexit 1で拒否し、`whole_call_stack_qualified=false`を記録する。
完全にmetadataが揃った人工的な閉じたgraphでも、このtoolは実stack合格にはしない。
branchの実行可能性、SPの各命令での変化、IRQ/kernelの別stackへの切替、間接call先、
実taskのpaint/guardは別途確認する必要がある。
10件のPython testで、古い7,008 B frame、未測定/間接/ROM境界、再帰等を見落とさないことを確認した。

## native回帰と再実行

通知sourceの追加を含むmanifestをversion 2へ進めた。RPC wireは2、reportとcontrol descriptorは1を維持し、以前のmanifest version 1と候補imageも現判定器で再監査できることを確認した。
native FSD候補を再linkし、fixture・resident hook/word・layout・frame・loaderとimageの監査が成功した。
imageは852,560 B、primary residentは106,176 Bで、policy上限まで320 B。
Python205件、format / ZLint / ShellCheck、既存6 native ELF link監査も成功した。
CIへinventoryの取得・保存を設定したが、今回の成功はlocal実行である。

```sh
# native候補のbuildは前回記録の環境変数を使う。
python3 tools/check-native-call-stack.py build/native-fatfs-wakeup/nihos-native.elf \
  build/native-fatfs-wakeup/call-stack.json --objdump riscv32-esp-elf-objdump
python3 -m unittest discover -s tools -p '*test.py'
```

残るgateはcall-chainの未解決箇所と実worker stackの観測、実機のIPI配送・task停止/wakeup、
実カードFatFsとcontroller fenceの接続である。clean POR、永続SQLite、書込み・電断耐性も未確認である。
