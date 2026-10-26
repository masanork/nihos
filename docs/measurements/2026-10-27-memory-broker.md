# 共通memory brokerの所有権と予算管理

2026-10-27。`codex/tab5-memory-broker`。設計は[ADR 0049](../adr/0049-memory-broker-page-parents.md)。
かな漢字入力・通信を含む予算を、実際のpage-parent割当てに適用するkernel部品を実装した。
ホストで実行し、RV32向けにcompileした段階で、native起動経路への接続・実機検証は次のgateとする。

## 実装した契約

- SRAM／PSRAMを別domainとし、class上限・owner予約・同時owner数を検査する。
- ページ丸め後の実消費をowner/groupへ計上し、失敗時にquotaやbackingを漏らさない。
- 4 MiB／8 MiBのpayloadは各4 MiB／8 MiBのbackingとなり、paddingも含めて公開前に消去する。
- owner、lease、pinはinstanceと非循環ticketで識別し、古いowner・別broker・改変slice・二重完了を拒否する。
- 非同期利用をpinで保持し、close後も完了までbackingと予約creditを返さない。
- `reclaimOne`はunpinned parentを一件ずつ回収し、最後にowner枠と予約を返す。
- domainのcapacity/free/peak/largestと、owner/groupの予約・使用量を取得できる。

brokerはservice単位のparent allocatorで、小さな文字列やSQL objectを4 KiBずつ割り当てるものではない。
arena/slabなどの子allocatorはparentを一度だけ課金する。metadata変更は一つのserviceが直列化する。

## 予算を実装へ落とした結果

224 KiBの内部heap枠は、**metadata予約16 KiB＋貸出しpayload 208 KiB**へ分ける。
既存のallocator/fragmentation枠16 KiBを使い、resident 112 KiBへ追加計上したり、同じ16 KiBを
kernelにも貸し出したりしない。候補mapでは高位heapの先頭`0x4ff73000..0x4ff77000`をmetadataへ充て、
高位payloadを`0x4ff77000..0x4ff9f000`の160 KiB、低位payloadを48 KiBとする。
service上限144 KiB＋最低空き64 KiBで208 KiBとなる。

PSRAMはboot等の2 MiBを除く30 MiBを登録し、service上限21.5 MiB＋最低空き8.5 MiBとする。
IMEは内部8 KiB／外部2 MiB、networkは内部64 KiB／外部3 MiBなど、JSON予算からpolicyを生成する。
既存のCPU別buddy heapをそのまま同時登録することはできず、排他的handoffが必要である。

## 検証

Zig Debug / ReleaseSafe各184件、Python予算・証跡判定器147件が合格した。
format/ZLint/ShellCheck、6種類の既存native ELF配置監査、RV32契約compileも合格した。
target metadataは12,912 Bで16 KiB予約内、compile probe自身のprologue frameは3,232 Bだった。
生成policyとtarget objectのhashは[構造化結果](2026-10-27-memory-broker.json)に記録する。

主要ケースは、全serviceを上限まで同時確保した際の両floor、全量回収、別owner/別instance/slot再利用、
pin二件の一回限りの完了、処理中の回収待ち、metadata枯渇、ticket枯渇、fragmentationによる失敗、
二domainで2,000回の混在alloc/freeと、全live bufferの先頭・末尾の照合である。
metadataをpayloadへ重ねた登録、既存brokerの再初期化、metadataコピーからの操作も拒否する。

大きな構造体を返してcopyするconstructorを避け、その場で初期化する。
RV32 compile probeのstack frameはassemblyから確認するが、calleeやIRQを含む最大使用量の保証ではない。
compile probeは実機やESP-EMUで実行したものではない。
ログ・object・assembly・sourceは
[ホスト検証archive](/Users/masanork/Documents/Codex/2026-10-27/nihos-memory-broker-host-rv32)へ保存する。

再現コマンド:

```sh
python3 tools/generate_memory_profile.py --check
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
python3 -m unittest discover -s tools -p '*test.py'
sh tools/run-static-analysis.sh
```

## 次の接続と実機gate

まずboot allocatorからのregion移譲とmetadata配置を実装し、既存heapとの二重所有を監査する。
次にapplication owner、scheduler quiescence、非同期I/O完了をRPCへ接続する。
close自体がtask停止やDMA abortを行うものではなく、pin tokenをuntrusted appへ直接公開しない。
pinが失われた場合はbackingを保持したままfaultとして扱い、timeoutだけで再利用しない。

Flash実行／cache停止／PSRAM／DMAの契約も別途確認する。続く実機試験では、強制終了と遅延完了、
slot再利用、通信・IME・SQL・GCの同時負荷、stackと最低連続空き、終了後の全量回収を確認する。
今回の更新だけで16 task化や無線・IMEの実機同時動作が完了したとは扱わない。
