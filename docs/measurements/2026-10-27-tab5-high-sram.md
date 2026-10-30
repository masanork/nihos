# Tab5: 追加SRAMとページleaseの実機検証

2026-10-27。実行ソース `8a66e2689714bc48bac3edcb2df5101094d3f7d1`、
ブランチ `codex/tab5-high-sram`。設計は[ADR 0048](../adr/0048-high-sram-and-page-leases.md)。
計画レビューで残っていた追加SRAMの実在・両CPUからの利用と、大容量割当ての丸めを確認した。
複数storage clientの並行作業とは別worktreeで実施した。

## 配置と実装

ESP32-P4 rev1.3、Flash 16 MiB、PSRAM 32 MiB、L2 128 KiB / line 64 B。
追加領域は pinned ESP-IDF v5.4.4 `memory.ld.in` のrev1/2 high RW window内。
低位160 KiB、loader/ROMの穴、稼働中stack 56 KiBは従来配置を維持する。

| 追加領域の使い方 | 範囲 | 容量 |
| --- | --- | ---: |
| DMA将来予約 | `0x4ff40000..0x4ff48000` | 32 KiB |
| stack将来予約 | `0x4ff48000..0x4ff5a000` | 72 KiB |
| ページpool A | `0x4ff5b000..0x4ff5f000` | 16 KiB |
| ページpool B | `0x4ff6f000..0x4ff9f000` | 192 KiB |
| software guard | 各poolの前後4 KiB、計4ページ | 16 KiB |
| 合計 | `0x4ff40000..0x4ff60000` と `0x4ff6e000..0x4ffa0000` | 328 KiB |

guardはpattern検査であり、書込み禁止のハードウェア保護ではない。
DMA・追加stackは予約だけで、使用・admission・DMA転送は未実装。
現在56 KiB＋将来72 KiBで計画のstack 128 KiB分の場所を確保した。

`src/kernel/page_pool.zig`は外部metadataの4 KiB page allocator。
owner/slot/ticket・元slice・charged pagesを検証し、別ownerや古いleaseの解放を拒否する。
最大2区間を扱い、区間をまたぐ連続allocationを許さない。caller側で直列化する。
このfixtureではCPU0だけがmetadataを変更し、4 workerに別々の4 KiBを渡す。
全worker完了後に回収する。一般アプリ向けの権限・自動回収APIではない。

## 実機結果

`/dev/cu.usbmodem101`を再確認し、同一exclusive descriptorをSDK参照実行、loader/app書込み、
開始前verify、3回のUSB RTS起動、終了後verifyまで保持した。partition tableは書換えず照合した。
ユーザーの指示通り追加バックアップは作成せず、SD sectorのwrite/eraseも行っていない。
電源を保持したresetで、cold bootや電源断試験ではない。

全3回で次を確認した。

- 追加328 KiBの全83,968ワードへCPU0がaddress patternと反転patternを2回write/read。
- CPU1が全ワードを検査して別patternを書き、CPU0が再検査。両CPUで同じ物理内容を確認。
- 208 KiBを分割して全量確保、容量超過・別owner解放・古いticket解放の3ケースを拒否。
- SMP実行中に4 workerが各pageの内容を検査し、終了後に全byteとguardを検査、208 KiB全量回収。
- 一般PSRAM heap初期化前の `0x48030000..0x48830000` で4 MiB、続いて8 MiBを確保。
  chargedは各4 MiB／8 MiBで、計3,145,728ワードをwrite/read。前後のwordと全量回収を確認。

| 起動 | 採取秒数 | PASS後監視秒数 | workerごとの追加SRAM検査回数 |
| --- | ---: | ---: | --- |
| 1 | 40.056 | 10.033 | 322732 / 319856 / 322753 / 319960 |
| 2 | 40.218 | 10.197 | 322253 / 320257 / 322241 / 320344 |
| 3 | 40.228 | 10.206 | 322561 / 320129 / 322616 / 320097 |

既存の300ラウンドSMP、64往復IPI、SD 1bit 400 kHz→4bit 400 kHz→4bit 20 MHz、
各段階1,024地点分散読出し、littlefs/API、強制終了・旧generation拒否・再接続・回収も全回合格。
SDK imageを今回新たに実行し、容量・固定LBA CRC・分散digest `524262a3`・FS/APIが全回一致した。
新旧clientの各10,752 BはCRC `883551bf`。後続SQLiteは2 session / 26 statementでheapが回復した。
FS parserは共通で、block IOが独立した比較である。

## メモリ予算への反映

exact ELFのprimary staticは112,128 B（109.5 KiB）、低位heap予約は51,712 B（50.5 KiB）。
新pool 208 KiBと合わせたheap予約は258.5 KiBで、256 KiBの計画に対する配置の根拠が得られた。
従来計画の未割当16 KiBは今回のsoftware guard 16 KiBへ振り替え、追加の空き領域として数えない。
低位arenaの実payload容量は各25,728 B、使用448 B、空き25,280 B。
page poolは208 KiB空きへ回復した。予約容量と現在のfree payloadを同一視しない。
稼働中stackは56 KiB、slot数も従来のまま。boot FSのpaint観測6,592 B、SQL 6,360 B、
owner 3,216 B、client 1,920 Bで、一般経路の最大stack保証ではない。

Zig Debug / ReleaseSafe各170件、Python判定器127件、format/ZLint/ShellCheck、
RV32 architecture contractと6 native ELF配置監査が合格した。高位bankはNOBITS/RW/非実行属性・
正確な境界・対の存在・linker symbol・loader非衝突を検査する。emulator profileは明示拒否する。
実機ログはimage auditと結び付け、欠落/重複/誤容量/未回収/倍増chargedを拒否する。
remote CIと追加領域のESP-EMU実行は行っていない。

## 固定画像と残り

app 775,744 B。app SHA-256:
`37ae2326c2d057860a35d371868ec2a39d203f74bb88b254f4dbb1580b15553e`。
ELF SHA-256: `2e38a53dfaa10ee15de5655b5e10b49c7c0e689b00da6f6cbeed853c95db7f4e`。

[構造化実機結果](2026-10-27-tab5-high-sram.json)。
[固定画像・全ログ・SDK比較・source・SHA256 manifest](/Users/masanork/Documents/Codex/2026-10-27/nihos-tab5-high-sram-qualification)。
最終照合時点でこの画像が本体にある。ポート解放後の変更は追跡しない。pushはしていない。

`NIHOS_NATIVE_HIGH_SRAM=1`はdevice限定のopt-inで、通常buildでは無効。
大容量PSRAM試験は一時借用windowで行い、そのleaseは既存heapへ持ち越さない。
既存PSRAM buddyの二分割・header・丸めは変更していないため、通常VM heapの制約解消完了とは呼ばない。
次は予約済みpoolを一般のmemory brokerへ接続し、小物用allocator、quota、task終了回収、
16 task用stack admissionと整合させる。SD書込み、永続VFS/SQL、電源断回復も引き続き未対応。
