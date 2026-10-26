# Tab5 native SD: 読取り専用block APIとlittlefsの実機検証

2026-10-26。前段の4ビット・20 MHz SDMMCから、既存カードのFS読取りへ進めた。
**native版でlittlefsをマウントし、ルート列挙と既存ファイルの全読取りに成功した。**
実行ソース `fbbce97`、ブランチ `codex/tab5-psram-physical-fix`。
同一最終画像の3起動で、SDMMC・FS・通常のnative SMP/PSRAM/SQLiteが全て合格した。
これはboot専有のqualification fixture。アプリ向けruntime VFSはまだない。

## 実装した範囲

- `src/storage/block.zig`: 同期・512バイト・read-onlyの型付きreader。
  容量、LBA境界、親領域内のsubregionを検査してからbackendへ渡す。
  2 TiBの最後のセクターもhost試験する。controllerの寿命と直列化は呼出側の責任。
  write/erase、動的確保、複数sector転送、並行利用のAPIはない。
- `probes/storage/littlefs_ro.c`: full-card littlefsの限定reader。
  512/4096バイトの2つのFS block geometryを試し、正規のlittlefsによる
  superblock/metadata検証に成功したものだけを受理する。magic文字列だけではmountしない。
- ルートを最大128項目まで列挙し、名前・型・サイズをdigestへfoldする。
  ルートの非空通常ファイルのうち64 KiB以下の最小のものを1つ選び、
  全データを512バイトずつ読み、CRC32とEOFを確認する。
  unmount後にもう一度mountし、列挙・選択した名前・全データが一致することを要求する。
  適切なファイルがない場合はdirectory-onlyの結果に区別し、ファイル読取成功とは扱わない。
- mountから全2回の処理を通してsector読出しを最大8,192回に制限する。
  callbackはFS block/offset/sizeを検査して512バイトLBAへ変換する。
  native callbackはboot試験中だけcontrollerを公開し、試験終了後は拒否する。
- upstream littlefs v2.11.3を変更せず、`LFS_READONLY` / `LFS_NO_MALLOC`でコンパイル。
  read/program/file cacheとlookaheadは固定領域。program/erase/sync callbackは拒否のみ。
  targetイメージからformat・file write・remove・mkdir・rename・truncateのAPIが
  除去されていることもELF監査する。SDMMC側のwrite/erase禁止も維持した。
- FSのCコードとrodataは、既存のSQLite mapped Flash spanを共有する。
  歴史的なsection名は `.flash.sqltext` / `.flash.sqlrodata` のまま。
  object manifestにFSの許可関数、source/object hash、read-only設定を追加し、監査対象にした。
  これはsourceとの対応を記録するもので、暗号学的な実行attestationではない。

ソースは[upstream固定revision](https://github.com/littlefs-project/littlefs/tree/6cb4e86540eca0d9ba62500a298385c9d863c8be)。
`tools/bootstrap-littlefs.sh`がSHA-256を確認してignored build cacheへ展開する。
BSD-3-Clauseの原文とcopyrightを証拠archiveに同梱した。
MeOSのソースは取り込んでいない。依存状態は`provenance.toml`に反映した。

## 実機のカードと比較結果

独立IDF版で先頭headerに`littlefs`があることを確認した後、FS blockのサイズを切り分けた。
**SD sectorは512バイト、実際のFS blockは4,096バイト**だった。

| 項目 | native全3起動とIDF版で一致した結果 |
| --- | --- |
| SD sector数 | 30,867,456 |
| littlefs block | 4,096 B × 3,858,432 blocks |
| ルート項目 | 4（通常ファイル3、directory 1。`.`/`..`を除く） |
| 列挙digest | `40e9d8c6` |
| 選択ファイルの名前digest | `33445ceb` |
| 選択ファイル全データ | 10,752 B / CRC32 `883551bf` |
| mount→列挙→全読取り→unmount | 各起動2回、結果一致 |
| FS処理のsector read | 各起動165回（geometry判定も含む） |
| program/erase/sync callback | 呼出し0 |

ファイル名や内容はログへ出さず、digest・サイズ・CRCだけを記録した。
全ファイル・全階層の走査ではない。CRC/digestは暗号学的な同一性保証ではない。

IDF版は通常のSDMMC SDKから同じカードを読み、**FSライブラリとqualification adapterは
native版と共有している**。独立なのはblock IO経路であり、別実装のFS parserとの比較ではない。
IDF版はFreeRTOSを使う比較用アプリ、native版にはRTOSをリンクしていない。
`check-sdmmc-oracle.py`が従来の固定LBA/分散sector照合を、
`check-storage-oracle.py`がFS結果をそれぞれ比較した。

## 最終画像の3起動

USB `/dev/cu.usbmodem101`、ESP32-P4 rev1.3、PSRAM 32 MiB。
開始前に前段のloader/table/app一致とserial所有を確認した。
以下はUSB RTSリセットで、本体のcold bootログではない。

| 起動 | 採取秒数 | 最終PASS後の監視秒数 | FS stack観測値 | SQL stack観測値 |
| --- | --- | --- | --- | --- |
| 1 | 37.362 | 10.194 | 6,752 B | 7,112 B |
| 2 | 37.354 | 10.186 | 6,752 B | 7,112 B |
| 3 | 37.370 | 10.202 | 6,752 B | 7,112 B |

各起動で先に1ビット400 kHz→4ビット400 kHz→4ビット20 MHzへ切り替え、
各段階1,024地点の分散読取と固定4地点の反復（計3,096読出し）を実行した。
全段階のdigest `524262a3` は今回の独立IDF版とも一致した。
その後FSが165読出し。**合計3,261読出し/起動、3起動で9,783読出し。SD sector書込は0。**
IDF版には別に3,096ではなく1,032＋165回の読出しがある。

FSの後も両CPUの通常300ラウンド、timer・IPI/idle、PSRAM mapping/coherence、heap回収、
SQLite 2セッション26文を判定した。SQL前後の空きは毎回16,022,848バイトに回復。
追加trap/fail・再起動はなかった。前段のPSRAM全ワード検査やSQL 1,000バッチは今回は無効。

FS自身にもstack paintを追加して観測した。8 KiB枠の下端guardを除き、
さらに160バイトtrap枠を差し引いた残りはFS 1,264バイト、SQL 904バイト。
固定fixtureの観測値であり、任意のFS操作・SQL・call graphの最大stack保証ではない。

最終appは750,144バイト、内部heapは49,856バイト。
48 KiBというlinker最低条件に対する余裕は704バイトで、常駐領域の追加前に配置を見直す必要がある。
FS adapterは動的確保を使わない。最終画像を本体に残した。画面・タッチは初期化しない。

- app SHA-256: `8de12f6d53d328710b414b53c8ce90516c8374963e64670eb9909b1f8720ec45`
- ELF SHA-256: `3747cfb67e00b3b05326c9810c8f991987ff1da265980a47cb5d36e222731369`

## 失敗の切り分けと回帰確認

最初のIDF FS試験は`LFS_ERR_NOMEM`（12）、読出し0回で失敗。
`LFS_NO_MALLOC`でもprogram cacheとlookaheadの明示指定が必要で、固定bufferを追加した。
次は`LFS_ERR_INVAL`（22）、3読出しで失敗。512バイトのFS blockを仮定したためだった。
512/4096のboundedなgeometry判定とsector変換を追加して解消した。
nativeリンク時に不足した標準`strcpy`は小さなC互換関数として追加し、
4,096ケースのhost libcとの比較・buffer guard・ASan/UBSanで確認した。
失敗したIDF画像・ログと、実行していない初期native画像も、成功画像とは別に保存した。

- Zig Debug / ReleaseSafe: 各159件。
- Python native evidence checker: 110件。FS欠落・異常geometry・file結果不一致・
  stack不足・異なるimageとの誤結合を拒否する検査を含む。
- ASan/UBSanのhost FS試験: 512/4096の両geometryで、2 mount、1,300 Bの既知データ、EOF、
  最初/2回目mount中のI/O失敗、容量不一致、両superblock破損を確認。期待CRCはPython zlibで別計算。
  writableなfixture生成器はhost専用で、targetにはリンクしない。
- formatting / ZLint / ShellCheck / RV32 architecture契約と6 native ELFリンク監査が通過。
- 通常ESP-EMU SQLite 32 MiBとinteger PSRAMなしも通過。FS/SDのエミュレーションではない。
- host FS試験とPython判定器試験をCI定義にも追加したが、push・remote CIは実行していない。

## 再現と残り

```sh
NIHOS_NATIVE_STORAGE=1 NIHOS_NATIVE_SDMMC=1 NIHOS_NATIVE_SDMMC_PROFILE=2 \
  sh tools/build-native.sh device sqlite
python3 tools/check-native-log.py BOOT.log REPORT.json sqlite 32M IMAGE-AUDIT.json physical-device sdmmc-fast,storage
python3 tools/check-sdmmc-oracle.py IDF.log REPORT.json SD-COMPARISON.json
python3 tools/check-storage-oracle.py IDF.log REPORT.json FS-COMPARISON.json
sh tools/run-storage-host-test.sh
```

storageは既定で無効。opt-in時はSDMMC有効とsqliteモード（Flash配置の共有）が必須。
実機監査には新しく生成されたloaderではなく、保持している元loader ELF/configを指定する。
loader/tableは保持し、書込みはapp `0x10000` のみ。Flash全量バックアップも保持した。
終了時にesptoolで実機のloader/table/app全3領域を再照合した。

- [固定画像・失敗例・原文license・全ログ・監査・source patch・SHA manifest](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-littlefs-readonly-qualification)
- [前段の4ビット・20 MHz検証](2026-10-26-tab5-sdmmc-wide.md)

次は内部SRAM/stack配置の余裕を作り、controller所有をboot fixtureからstorage ownerへ移し、
アプリ向けread-only file APIとrequest/completion経路をつなぐ段階。
現状はcontroller全体を初期化するためC6 Wi-Fi/slot 1との共存は未対応。
partition（MBR/GPT）内のFS、FAT/exFAT、一般的なmount選択、全階層の検査、runtime VFS/RPC、
SD書込・永続SQL VFS・電源断回復は未実装/未検証。mainへの反映・pushは行っていない。
