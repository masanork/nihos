# Tab5での追加実機検証とnative SDMMC読取試験

後続の[4ビット・20 MHzと分散読取の実機検証](2026-10-26-tab5-sdmmc-wide.md)も参照。

2026-10-26。前段のPSRAM修正後、USB接続中の実機で検証を進めた。
最終ソースは `57d9697`、ブランチは `codex/tab5-psram-physical-fix`。
**FPの実機確認、PSRAM全ワード検査、SQLite反復実行、native SDMMCの読取が成功した。**
SDMMCは400 kHz・1ビット・SDHC/SDXCの単一セクター読取に限定した初期実装。
書込・消去・フォーマット・ファイルシステムは実装していない。

## 接続と証拠の区別

- 実機: Tab5 / ESP32-P4 revision 1.3、Flash 16 MiB、PSRAM 32 MiB。
- ポート: `/dev/cu.usbmodem101`。操作前に他の所有プロセスがないことを確認。
- 各アプリは `0x10000` だけに書込み。元候補のloader/tableを保持した。
  最終的にloader、table、appの全3領域をesptoolで再照合した。
- 実機用監査は、新規ビルドされたloaderではなく、実際に保持した元loaderの
  ELF/configを指定した。各ケースのELF/app/監査/ログを個別に保存。
- 既存Flashの全量バックアップと、元のdirtyなmain作業ツリーは保持。
- 以下の起動反復はUSB RTSリセット。**本体を完全に電源断した試験ではない。**

## 浮動小数点とメモリ・SQLの試験

| 試験 | 実機結果 |
| --- | --- |
| RV32Fの明示的レジスタbankを使うfloatingモード | 同一イメージで3起動合格。両CPU、timer/task/IPI、FP保存・復元、終了時回収を判定 |
| コンパイラ生成Zig/C・ILP32Fのcompiledモード | 同一イメージで3起動合格。計算結果と生成コード中のpreemptionも判定 |
| PSRAM全容量CPU検査 | 32 MiB全ワードを、アドレスから生成した値と反転値で書込み・読出し。各16,777,216語、計128 MiBのデータアクセス |
| SQLite反復 | 1,000バッチ、2,000セッション、26,000文。各バッチで開閉し、heapが毎回回復 |
| 反復終了後の通常SQL fixture | さらに2セッション・26文を実行し、通常のnative SMP/heap/stack判定も合格 |

全容量検査はCPU1の解放と外部heap登録の前に破壊的に実施する。
SDカードやFlashへの書込みではない。CPUマッピング上の全ワードの2パターン検査であり、
全電圧・温度・周波数・全ビットパターン・PSRAM DMAの資格試験ではない。

反復用イメージ全体の採取時間は331.69秒（最終表示後の監視10秒を含む）。
SQLite前後の空きは16,022,848バイト、反復時のstack観測値は6,520バイト。
この時間には起動と全容量検査も含まれるため、SQL単体の処理時間とは扱わない。
SQLはCPU0 bootstrap上、タイマー停止後に実行する。長時間の並列SQLサービスではない。
FP画像は前段の `57f4e90`、反復画像はその後の作業中のソースから固定した画像であり、
後から追加したSDMMCを含む最終画像とは区別して保存した。

## SDMMC実装と独立した比較試験

追加したものは `src/soc/esp32p4/sdmmc.zig` のboundedなprotocol処理、
`src/platform/native/sdmmc_probe.zig` のboot fixtureと固定DMA領域、
`probes/sdmmc/pads.c` の小さなpin/power/clock shim。
shimはESP-IDF v5.4.4のLLヘッダを利用するが、SDKアプリruntimeやFreeRTOSはリンクしない。
nativeイメージの命令・ROM・メモリ配置監査も通過した。

- Tab5 slot 0: D0=39、D1=40、D2=41、D3=42、CLK=43、CMD=44。
- LDO4をソフトウェア所有にし、全信号をfloatさせて250 ms off後、3.3 V rail bypassを設定。
  CMD0時にD3が低くならないよう扱う。これはSD用railの制御であり、本体全体の電源断ではない。
- CMD0/8、CMD55+ACMD41、CID/RCA/CSD、select/statusの順で初期化。
- 受理するコマンドは `0,2,3,7,8,9,13,17,41,55` に限定。
  CMD24/25や消去系コマンドを送るAPIはない。
- 内部SRAM上に64バイト整列した512バイトstaging bufferと、1個の64バイトDMA descriptor。
  cache writeback/invalidate、DMA完了・descriptor所有権、エラー・timeoutを検査する。
- pollは有限。DMA失敗後はengineを停止し、controllerを再利用不可にする。
  停止自体が失敗した場合も内部状態に保持し、記述子を再利用しない。割込み・動的確保は使わない。

検出容量は**30,867,456セクター**（512バイト/sector）。
先頭、次、中央、末尾を2回ずつ読み、各回のCRC一致を要求した。

| LBA | native DMAと独立IDF版で一致したCRC32 |
| --- | --- |
| `0x00000000` | `9022e83d` |
| `0x00000001` | `bd7bc39f` |
| `0x00eb8000` | `c6d765f6` |
| `0x01d6ffff` | `c6d765f6` |

独立IDF版は `probes/sdmmc/oracle/`。通常のIDF host/protocol/DMAで同じ8読出しを行う。
ファイルシステムはmountしない。**この比較用アプリはFreeRTOSを使い、native実行の証拠とは別。**
`tools/check-sdmmc-oracle.py` が容量、LBA順序、反復一致、nativeとの全4 CRC一致を確認する。

## 保存した失敗

最初のPIO版は、FIFO_COUNTが残り語数を超えてShortReadになった。
1語ずつ読む版では反復一致・完了表示まで進んだが、独立IDF版との照合で
**LBA 0のCRCが `727d4ab1` となり不一致**だった。10 usの追加待ちでも変わらなかった。
このPIOデータ不一致の根本原因は断定していない。

そのためPIOを製品側の経路から除き、固定内部DMAに置き換えた。
変更後は全4 CRCが独立版と一致した。均一データの他3セクターだけではこの不具合を
見落とすため、同じnative readerでの反復一致だけを合格条件にはしなかった。
失敗画像・ログ・PIOソースは成功例と別に保存した。

## SDMMCとSQLiteを同じnative起動に統合

`968a030` のSDMMC＋SQLite画像は3起動で全判定・独立CRC照合に合格。
DMA異常時の再利用禁止を強化した `97bdfcb` も1起動で合格。
最後にSD初期化関数をnoinlineにして一時bufferのstack枠を戻すようにした
**`57d9697` の最終画像も1起動で全判定・CRC照合に合格**した。
各起動で300ラウンド、両CPU、PSRAM、IPI/idle、heap回復、通常SQL 26文まで実行。
最終表示の後も10秒以上観測し、追加trap/fail・再起動はなかった。

最終アプリは734,400バイト、内部heapは60,992バイト。
アプリSHA-256は `f84c32fb3f449e4ba674b01c23776bb4802cb63db7c8d6ee70f5ae2ebbcedd20`。
SDMMC＋SQL fixtureのstack観測値は、関数分離前の7,152バイトから**6,648バイト**になった。
8 KiB枠の下端guardを除いて1,528バイト、160バイトのtrap枠を差し引くと1,368バイト残る。
これは固定fixtureのパターン走査結果であり、任意SQLの最大stack保証ではない。
現物にはこの最終SDMMC＋SQLiteイメージを残した。画面・タッチは初期化しない。

## 検証・再現・次の段階

- host Zig Debug / ReleaseSafe 各153件、Python native検査102件が通過。
  コマンドallowlist、CSD容量境界、DMA timeout/所有権/停止失敗/再利用禁止、
  不完全な追加検証ログ、oracle不一致・欠落・順序異常などを含む。
- formatting / ZLint / ShellCheck / RV32 architecture / 6 native ELFリンク監査が通過。
- 最終ソース系列で通常のESP-EMU SQLite 32 MiB・integer PSRAMなしを回帰確認。
  **エミュレータでSDカードの実装を検証したものではない。**
- [画像・失敗例・監査・ログ・構造化結果・patch](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-hardware-qualification)
- [初回書込み前のFlash全量バックアップ](/Users/masanork/repo/nihos-device-backups/20261026-before-native-sqlite-ed3e34f.bin)

```sh
# Full CPU PSRAM sweep + 2,000 SQL sessions; default build does neither.
NIHOS_NATIVE_QUALIFICATION=1 sh tools/build-native.sh device sqlite
# Read-only SDMMC boot probe + ordinary native/SQLite fixture.
NIHOS_NATIVE_SDMMC=1 sh tools/build-native.sh device sqlite
```

追加検証を要求する判定器の末尾引数は `qualification` または `sdmmc`。
両方を実行する画像では `qualification,sdmmc` を指定できる。
画像は例ごとに固定してから書き込み、ログと同じ画像の監査結果で判定する。

次に実機で詰めるのは4ビット/20 MHzと、カード未挿入・異常応答からの再試行方針。
その後、read-only block API、カード形式の判別、read-only filesystemへ進める。
現段階はboot専有で、SDMMC controller全体を初期化するため、C6 Wi-Fi/slot 1との共存や
runtime storage service/RPCへ進む前にコントローラ所有・仲裁を設計する必要がある。
SDSC、複数sector、PSRAM向けDMA、SD書込・永続VFS・電源断回復は未実装。
本体の完全電源断起動は手動操作が必要なため今回は未実施。
公開mainへの反映・push・リモートCI起動は行っていない。
