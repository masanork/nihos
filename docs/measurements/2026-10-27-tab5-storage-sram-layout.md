# Tab5: boot SD codeのFlash配置で内部SRAMを回復

2026-10-27。実行ソース `1182a74`、ブランチ `codex/tab5-psram-physical-fix`。
[前段のendpoint再接続](2026-10-26-tab5-storage-rebind.md)で残り512 Bだった
内部heap最低値への余裕を、boot専用SD検査コードの配置変更で増やした。
設計は[ADR 0047](../adr/0047-boot-sd-code-in-mapped-flash.md)。

## 変更と配置監査

`sdmmc_probe.run`だけを`.flash.text.sdboot`へ置き、既存の最初のmapped Flash pageへ連結した。
同関数はPSRAM mappingを準備した後・CPU1 release前に一度だけ呼ぶ。
DMA staging/descriptor、runtime controller/read callback、scheduler/IRQ hooks、mutable kernel state、
IRQ/task stackは内部SRAMを維持する。PSRAMへ新しいkernel stateは移していない。
heap最低値48 KiB、primary SRAM 160 KiB、stack bank 56 KiB、loaderのmapped segment数も維持した。

image auditはSD bootの正確な一関数の範囲、他のboot関数との隙間/重なり、
DMA bufferのサイズ・64 B alignment・内部SRAMへの全体包含、runtime callbackのresident配置を検査する。
任意helper/IRQのFlash移動を許可するprefixは追加していない。
関数内の`auipc`で実行PCを採り、return後の`NIHOS_NATIVE_SDMMC_CODE`で範囲・PC・完了を記録する。
log checkerは画像と一致する範囲、範囲内のPC、completed=1、記録の重複/欠落なしを要求する。
従来の`NIHOS_NATIVE_BOOT_CODE`はPSRAM probe/mappingの完了記録で、新しいSD記録と区別する。

| exact ELFの内訳 | 前段 `6c99109` | 今回 `1182a74` | 差 |
| --- | ---: | ---: | ---: |
| primary static予約 | 114,176 B | 104,192 B | -9,984 B |
| 内部heap予約 | 49,664 B | 59,648 B | +9,984 B |
| 48 KiB最低値への余裕 | 512 B | 10,496 B | +9,984 B |
| `.text` | 96,670 B | 86,786 B | -9,884 B |
| `.rodata` | 4,456 B | 4,456 B | 0 |
| `.data` | 7,632 B | 7,632 B | 0 |
| `.bss` | 5,248 B | 5,248 B | 0 |
| Flash boot code | 4,280 B | 14,470 B | +10,190 B |

heapは`0x4ff1be00..0x4ff28000`から`0x4ff19700..0x4ff28000`へ広がった。
差分には実行位置の記録用codeとlinker alignmentも含むため、関数のbyte数とは一致しない。
前段は保存済みの実機資格画像/ELF、今回は固定最終画像/ELFのauditを使う。
これは配置容量の比較であり、速度改善・帯域改善の比較試験ではない。
内部heapは各hartの既存arenaへ分割され、実機ログの境界/容量/回収確認も継続する。

## 実機fixture

ESP32-P4 rev1.3、Flash 16 MiB、PSRAM 32 MiB、`/dev/cu.usbmodem101`。
同じexclusive serial descriptorでSDK referenceを新規実行し、既知loader/native appを書込み、
開始前verify、3回のUSB RTS起動、終了後verifyまで完了した。
ユーザーの上書き指示に従い、新たなdevice backupは作らず、loader/appだけを上書きしてpartition tableを保持する。
SD sectorのwrite/eraseは行わない。

新PC sampleは`0x40001254`。画像上のSD boot範囲`0x400011d8..0x400039a6`内にあり、完了値は1。
Flash boot全体の末尾も`0x400039a6`で64 KiB page内に収まる。
これは指定boot関数の実行位置と正常returnの証拠で、call graph全体やcache-off実行の証明ではない。

従来と同じ以下のfixtureが全3起動で合格した。

- SD 1bit 400 kHz→4bit 400 kHz→4bit 20 MHz、各段階の分散1,024地点と固定LBA、read-only FS/API。
- 300ラウンドSMP/PSRAM/heap、64往復IPI、guardとresource ledgerの検証。
- 未完了RPCを残したCPU1 client強制終了、処理中readの完了、要求2件・応答2件の破棄、handle release。
- 同じtask slotのgeneration 3→4再利用、epoch 1→2再接続、古い要求/合成応答/handle/終了通知の拒否。
- 新旧client各10,752 B全読取り、CRC32 `883551bf`、FS 8 KiB/IPC 8 KiB消去。
- 後続SQLite 2セッション26文とheap回復。

runtimeのbackend operation 62、client受信response 63、拒否8、旧handle拒否2という前段の判定を維持する。
古い応答は意図的にqueueへ注入する合成fixtureで、実際の遅延replyを観測したものではない。
取消しbarrierは同期read/DMA完了後・response publish前で、DMA途中abortや任意命令位置killの検証ではない。

SDK referenceは保存済みのSDK imageを今回新たに実行したもの。
boot容量・固定LBA・分散digest・FS/APIを独立したSDK block IOと比較し、runtimeの両file CRCをboot結果と照合し、全比較が合格した。
FS parser/backendは共通なので、別実装parserとの比較ではない。

## 検証と残り

Zig Debug / ReleaseSafe各166件、Python判定器120件が合格。
新しい判定器試験は未承認Flash code、欠落/重複した関数、誤ったlinker範囲、DMAのPSRAM/Flash移動や
alignment/size違反、PC/完了記録の欠落・重複・範囲外を拒否する。
formatting/ZLint/ShellCheck、RV32 architecture contractと6 native ELFリンク監査も合格。
SD/新RPC経路をESP-EMUで実行したものではなく、remote CIも未実行。

次は複数同時clientと同じCPUの任意workerとのpreemption。
今回増やしたのは内部heap予約であり、scheduler slot/worker stack数は増やしていない。
owner/controller再起動、FS破棄後のtoken管理、電源をまたぐepoch、一般アプリ向けsyscall/権限分離、
C6 Wi-Fi/slot 1仲裁、hot removal、FAT/exFAT、SD書込み、永続SQL VFS、電源断回復は未対応・未資格確認。
TG0 periodic alarmは従来IPI phaseからdisarmのまま。
USB RTS resetによる検証で、cold boot、PSRAM全ワード検査、SQL 1,000バッチは今回の対象外。
mainの並行作業は変更せず、pushは行っていない。

## 固定画像と測定値

全3起動で追加trap/fail・再起動がなく、PASS後も10秒以上監視した。
SDK比較と最後のloader/partition table/app照合まで同じexclusive descriptorを保持した。

| 起動 | 採取秒数 | PASS後監視秒数 | owner区間のTG1 counter差 | 同区間のCPU1 bootstrap poll |
| --- | --- | --- | --- | --- |
| 1 | 37.519 | 10.202 | 140,781 | 5,237 |
| 2 | 37.519 | 10.203 | 140,685 | 5,252 |
| 3 | 37.319 | 10.004 | 140,766 | 5,245 |

TG1は1 MHz設定とreadbackを確認したが、外部計測器で周波数は検証していない。
owner区間はruntimeのmount・RPC・旧新client読取り・取消し・再接続・回収を含み、boot SD検査を含まない。
全3起動でowner stackは3,216 B、client二世代の最大は1,920 B、boot FSは6,480 B、後続SQLiteは6,248 B。
4 KiB task stackからguard 16 Bとtrap 160 Bを除く残りはowner 704 B、client 2,000 B。
paintによる固定fixtureの観測値であり、一般pathの最大stack保証ではない。

内部arenaは各hartともcapacity 29,696 B、used 448 B、free 29,248 B、confirmed=1。
後続SQLiteのPSRAM heap空きは16,022,848 Bへ回復した。
最終appは769,168 Bで、前段768,864 Bより304 B増えた。

- app SHA-256: `dc3f4c70830e0d5a80afccddb5cf1b413d5cb705b8bf31cadde5a7e6a5999475`
- ELF SHA-256: `05f72daa672f60284d18ba85c58be182a80a688057ba0600ff1db080ba7aa628`

[固定画像・全ログ・前後メモリ比較・SDK比較・audit・source patch・license・SHA256 manifest](/Users/masanork/Documents/Codex/2026-10-27/nihos-tab5-storage-sram-qualification)。
終了時点でこの画像を書込み・照合した。ポート解放後の他セッションによる変更は追跡していない。
