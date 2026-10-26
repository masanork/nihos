# Tab5 native PSRAM修正とSQLite実機確認

2026-10-26。修正コミット: `edbdd6c`。基準: `ed3e34f`。
**修正版は、接続中のTab5で3回のUSBリセット起動試験に合格した。**
PSRAM 32 MiB、両CPU、外部ヒープ、SQLite 2セッション・26文を各起動で確認した。
SDMMCや永続ストレージを追加した変更ではない。

## 原因と修正

1. **MSPI3の4バイトアドレス有効ビットが欠けていた。**
   `USER1.USR_ADDR_BITLEN=31` だけでは不十分だった。
   `CACHE_FCTRL.CACHE_USR_ADDR_4BYTE`（offset `0x3c`、bit 1）を
   read-modify-writeで設定した。ESP-IDF v5.4.4のレジスタ定義と、接続中の
   ECO2 ROMの `esp_rom_spi_cmd_config` 実装でも、この追加設定を確認した。
   ROM呼出しを新しく追加したわけではなく、既存のnative MMIO処理を修正した。
2. **L2だけのcache同期では実機のCPU/command検査が通らなかった。**
   識別修正後、MSPI3のコマンドI/Oは通ったが、CPUが中間ページに書いた値を
   command側から読めなかった。ROMの同期対象をL2のみ（`0x20`）から
   shared L1 data + L2（`0x30`）へ変更すると、非identity mappingの双方向検査と
   コア間転送が通った。この試験だけから全cache構成の特性は一般化しない。
3. **ログ判定器が実機にもエミュレータのSRAM下限を適用していた。**
   エミュレータは `0x4ff20000..0x4ff48000`、実機rev1/2は
   `0x4ff00000..0x4ff28000`。device profileでは後者を検査し、その後も
   image auditの実際のheap領域・owner分割との完全一致を要求するよう直した。
   範囲・容量・guard・owner重複の検査は緩めていない。
4. **PSRAM失敗後に最終PASSまで進む表示を止めた。**
   unsupported/unstable/timeout、または検出後のI/O・mapping失敗は、診断記録を
   出した後 `NIHOS_NATIVE_FAIL PSRAM qualification` で停止する。
   PSRAMなしを明示する既存のabsent試験経路は保持した。

変更箇所: `src/soc/esp32p4/psram.zig`、`src/platform/native/psram_memory.zig`、
`src/platform/native/main.zig` と、PSRAMモデル・ログ判定器の回帰試験。
切り分け専用の追加出力は最終イメージから取り除いた。

## 段階ごとの実機観測

| イメージ | 識別・コマンドI/O | CPU/command・SMP | 結果 |
| --- | --- | --- | --- |
| 元候補 `ed3e34f` | config/identityが両方 `0x8d30`、unsupported | 未実行 | 前回の3起動で失敗、SQLite 0文 |
| 4バイトgateのみ追加 | config `0x8d28`、identity `0xa0df`、32 MiB検出。25アドレス×2パスの書込/読出し成功 | 中間物理アドレス `0x01000000` で不一致 | 失敗イメージを保存 |
| 同じ条件に物理アドレス診断を追加 | 同上 | 同じmapping不一致を再現 | 診断イメージを保存 |
| 診断版のcache対象をL1 data + L2に変更 | 成功 | MMU/cache検査・64回のコア間転送・外部ヒープ成功 | 修正した判定器でinteger合格 |
| 最終修正版 `edbdd6c` のSQLiteモード | 成功 | 成功 | 同一イメージで3起動すべて合格 |

失敗画像・ログは成功画像で上書きせず、別のフォルダに保持した。
実機ログから「先頭のみ通過」「L1を含めると通過」を切り分けたものであり、
オシロスコープによるバス信号・電圧・タイミングの測定ではない。

## 最終イメージと実機結果

- 接続先: `/dev/cu.usbmodem101`、ESP32-P4 revision 1.3、Flash 16 MiB。
- アプリ: **727,952バイト**。元候補から96バイト増加。
- アプリSHA-256: `98c0eb1bbf2625f61f6f25955f9e8f0158073684301e6c90074ca4b50a4c266d`。
- 内部heap: **68,096バイト**。stack領域は別に57,344バイト。
- stock loader/tableは元候補と同じものを使い、アプリだけを `0x10000` に書き込んだ。
  esptoolによる書き込み後ハッシュ照合は成功した。

各起動で以下を確認した。ログ判定器には `sqlite 32M image-audit.json physical-device`
を指定し、書き込んだものと同じ保存済みイメージの監査結果と照合した。
新規ビルドしたloaderは元候補のloaderとハッシュが異なるため、実機に保持した
元loaderのELF/configで `image-audit-actual-loader.json` を再生成して画像監査し、
全3ログも再判定した。実機用の同梱loader/tableは、この保持したものと一致する。

| 検査 | 各起動の結果 |
| --- | --- |
| PSRAM識別・モード設定 | 32 MiB、MR0=`0x28`、MR4=`0x40`、MR8=`0x0b` |
| コマンドI/O | 25アドレス、2パス、50書込・50読出し |
| MMU/cache | 全1,024エントリをreadback。CPU検査36・command検査36 |
| コア間PSRAM転送 | 64ラウンド、両CPU各3,072検査、command側48検査 |
| タイマー・タスク | 両CPUで300ラウンド、preemption、sleep/exit/reap、枠の再利用 |
| IPI/WFI | 両方向各64通知・配送・起床、タイマーfallbackなし |
| 外部heap/タスク所有メモリ | 確保・解放・不正操作拒否・pool/slab/C allocator・終了時回収。最終live=0 |
| SQLite | 2セッション、計26文。算術、UTC、CREATE、transaction、INSERT、集計 |
| SQLiteのFlash上実行 | `nih_sqlite_session_open` のPC=`0x4009c914`、監査した関数内 |
| SQLiteのheap | 前後とも **16,022,848バイト**。各セッション終了時に全回収 |
| stack観測 | 変更パターンから6,472バイト。一般的な最大stack保証ではない |
| 最終表示後 | 10秒以上観測。追加trap/fail・再起動なし |

合計6セッション・78文。3回とも同一の書き込み済みイメージをUSB RTSでリセットした。
SQLはCPU0 bootstrap上で、タイマーを止めた後に実行する。MIEは有効。
スケジュールされたSQLサービスや任意のSQLの耐久性は検証していない。

## 回帰試験

- host Zig: Debug / ReleaseSafe、各149件。
- Pythonのnative判定器・画像・記録検査: 94件。
- 4バイトgateを再び欠落させた変異ソースが、host回帰試験で失敗することも確認。
- formatting、ZLint、ShellCheck、RV32 architecture検査、device/emulator計6 ELFリンク監査。
- ESP-EMU: 12構成すべて合格。integerの0/4/8/16/32/64 MiB、floatingの0、
  compiledの0/32 MiB、SQLiteの0/4/32 MiB。各構成の画像・監査・完全ログを保存。

元候補を今回の修正済み判定器で再判定してもPSRAM失敗として拒否する。
判定器だけの変更で元候補を合格扱いにしたわけではない。

## 証拠・再実行・残る範囲

- [画像、失敗診断、最終3起動ログ、採取スクリプト、各種検証ログ](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-psram-fix)
- [実機3起動の詳細JSON](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-psram-fix/physical-sqlite-fixed/sqlite-fixed-results.json)
- [元候補の不合格記録](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-native-sqlite-physical-test/report.md)
- [最初の書込み前Flash全量バックアップ](/Users/masanork/repo/nihos-device-backups/20261026-before-native-sqlite-ed3e34f.bin)

修正ソースのブランチは `codex/tab5-psram-physical-fix`。
恒久作業ツリー: `/Users/masanork/repo/nihos-psram-fix`。
ビルドは `sh tools/build-native.sh device sqlite`、エミュレータは
`sh tools/run-native-smoke.sh sqlite 32M`。
シリアルの所有者を確認してから保存済みアプリを `0x10000` に書き込み、
同梱の `capture.py` と判定器で起動ログを採取・検証できる。

実機には修正済みSQLiteイメージを残している。画面とタッチを初期化しない試験版。
電源を実際に断った起動、PSRAM全セル・高温/低温・高クロック、任意SQLのstack上限、
長時間の反復SQLは未検証。SDMMC、永続VFS、電源断回復、nativeの画面統合も未実装。
ローカル実機・host・エミュレータの結果であり、push後のリモートCI結果ではない。
