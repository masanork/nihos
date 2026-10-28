# task側のtrap予算と、未提供frameのSP解析

2026-10-28。base `7f182b0`。前回のcall-chain inventoryに残っていた関数について、
最終ELFの命令とGNU objdumpのCFGからローカルSPの減少量を求める解析を追加した。
[結果JSON](2026-10-28-fatfs-sp-flow.json)にcandidate / tool / sourceのhashと解析結果を保存した。
実機実行、serial接続、Flash書込み、電源操作は行っていない。

## task側にも保存される128 B

native trap入口はtaskのSPを128 B下げ、integer contextを保存してから専用IRQ stackへ移る。
したがってworker 4,096 Bからguard16 Bとcontext128 Bを除いた通常処理のSP予算は**3,952 B**となる。
このreserveは`start.S`の`NIH_CTX_SIZE`からabsolute symbolとしてexportし、image判定器で128 Bを要求する。
worker / guard / Zig integer contextのlayoutもnative側のcomptimeで照合する。
これはIRQ stack自体の全call graphや、入れ子の例外処理を検証したという意味ではない。

system-call wrapperにfunction typeとsizeを付け、未測定targetではなく`ecall`境界として追跡できるようにした。
変更前候補と比較し、全executable PROGBITS sectionのaddress / size / SHA-256は一致した。
imageは852,560 B、residentは106,176 Bで、従来のpolicy上限まで320 B。stack領域は拡張していない。

## ローカルSP解析の範囲

[riscv_stack_flow.py](../../tools/riscv_stack_flow.py)はfunctionのELF byte列でinstruction幅とSPへのwriteを確認し、
GNU objdumpの分岐・復帰をworklistでたどる。対応するSP変更は定数`addi sp,sp,imm`に限定する。
各CFG joinでSPが一致しない場合、動的SP変更、未対応opcode/幅、命令欠落、未復元return/tail、
entryより上へのSP移動、call時のSP非整列、context return等を拒否する。
callから戻った後のSP保存はABI上の仮定として結果へ残す。
SP経由以外のstore、red zone、alias先、callee/ROM/IRQ内のmemory footprintは証明していない。

新candidateの到達可能なmetadata未提供13関数のうち12関数で解析が成功した。
stack paint / system-call wrapperはローカルSP減少0 B、identity / strlen / memcmp / memset /
memcpy / 除算helperは16 B、memmove / printは32 B、failは16 Bだった。
`nih_native_task_failed`は末尾のcallから先をモデル化できず、解析を打ち切って未確認として残した。
calleeが戻らないことを推測して0 Bに置き換えていない。

## 間接callbackを落とさず、仮定も消さない

`--candidate-edge disk_read:nih_fatfs_fixture_read`でfixture callbackを候補calleeへ追加した。
これにより、callback→fixture gate→fatal loggingまでのcostも到達可能な経路に含める。
ただしcallbackがそのtargetだけだという証明にはならないため、間接callの未解決表示は残す。
別名・targetの欠落、曖昧なcaller、複数のindirect call site等は拒否する。

既知frameとローカルSP減少の構造上の合算は、入口3,072 B、FSD3,056 B、client272 Bとなった。
前回より数字が増えたのは、未提供frameとcallback候補を取り込んだためである。
**実行可能な全経路のstack上限・下限ではない。3,952 Bとの比較だけで合格にしてはならない。**
入口には未確認1関数と未解決transferを含む9関数が残る。
jump table、cancel callback、disk callbackの排他性、ecallでのstack切替、ROM putc等は引き続き未解決である。
`--require-closed`はexit 1で拒否し、`whole_call_stack_qualified=false`を保存する。

## 検証と再実行

Python216件が成功。新しいSP解析の8件のtestでは、stackが増え続けるloop、矛盾したjoin、
動的SP変更、復元しないreturn/tail、未対応命令、途切れたCFG、call非整列等をnegative controlとした。
candidate edgeを加えても排他性の証明やgraph合格に変わらないこと、trap reserve改変の拒否も検査した。
Zig Debug / ReleaseSafeの既存243件の回帰はcache済み成功。format / ZLint / ShellCheck、
既存6 native ELF link、新candidateのELF/image/loader監査、旧manifest version1/2のimage再監査も成功した。
CIへ同じSP解析と候補edgeを設定したが、今回の記録はlocal実行である。

native source manifestは3へ進め、start.S / context offsets / stack layoutのsource同一性を加えた。
旧source manifest1/2は引き続き再監査できる。RPC wire2、report1、control descriptor1は変更していない。

```sh
python3 tools/check-native-call-stack.py build/native-fatfs-stack/nihos-native.elf \
  build/native-fatfs-stack/call-stack.json --objdump riscv32-esp-elf-objdump \
  --derive-frames --candidate-edge disk_read:nih_fatfs_fixture_read
# --require-closedを加えると、このcandidateは未解決箇所があるためexit 1になる。
```

残るgateは未確認frameと間接/ROM/assembly境界、実worker stackのpaint/guard、
実機のIPI配送・停止/wakeup、実カードFatFsとcontroller fenceの接続である。
clean POR、永続SQLite、書込み・電断耐性も未確認のままである。
