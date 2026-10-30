# Tab5 native SQLite候補の実機試験と実装状況

実施日: 2026-10-26。対象は別セッションでUSB書き込み権限が得られず保留された
`ed3e34f3847716cd397bc2f188c9bcafdc26c09c`。**実機試験は不合格**。
SDMMC対応は、この候補にも現在のメイン作業ツリーにも実装されていない。

## 対象の区別

- メイン作業ツリー: `/Users/masanork/repo/nihos`、調査時HEAD `196b354`。
  既存の未コミット作業は変更していない。
- 候補のソース: `/private/tmp/nihos-c-allocator`、ブランチ
  `codex/task-local-c-allocator`、HEAD `ed3e34f`。試験前後ともclean。
- 書き込んだアプリ: 727,856バイト、SHA-256
  `4a61deb5f059c45ac042110326bad6a8b134fda478461c59cc8e7c3831a836d0`。
- 別セッションの候補パッケージの全12ファイルをmanifestと照合し、一致を確認。
  今回は再ビルドせず、固定済みの実機用イメージそのものを試験した。
- 公開mainへの反映・push・CI起動は今回の作業に含めていない。

## 実施した操作

ポートの利用プロセスがないことを確認後、esptool v4.12.0で識別した。
接続先は `/dev/cu.usbmodem101`、ESP32-P4 revision 1.3、40 MHz XTAL、
USB Serial/JTAG、Flash 16 MiB。今回は読み書き可能だった。

書き込み前にFlash全16 MiBを保存した。その後、候補のstock loader、partition table、
nativeアプリをそれぞれ `0x2000`、`0x8000`、`0x10000` に書き込んだ。
esptoolのデータハッシュ検証は3ファイルとも成功した。
空白領域も含むmergedイメージは書き込んでいない。

同一イメージのUSB RTSリセット起動を3回採取した。各回は約19秒、
最終marker後も10秒以上観測した。通電を保ったリセットであり、電源断起動ではない。

## 実機結果

| 項目 | 3回の観測結果 |
| --- | --- |
| ROM/loaderから独立Zig native起動、CRT、例外復帰 | 全回到達。アプリにFreeRTOSなし |
| 両CPUのheartbeat、両タイマー | 全回300ラウンド進行。各100ラウンドのチェックポイントも3回到達 |
| タスク切替・sleep・exit・再回収 | 両CPUの記録あり。終了後のタスク枠再利用記録もあり |
| IPIとWFI待機 | 全回64交換、タイマーフォールバックなし。両CPUの送受信・通知・起床は各64 |
| SRAM領域・分離したスタック・Flash診断表 | 確認レコードあり |
| PSRAM供給設定 | calibrated=1、dref=7、mul=5、programmed=1、settled=1 |
| PSRAM識別 | **全回失敗**。configurationとidentityが両方 `0x8d30`、status=2（unsupported）、bytes=0 |
| PSRAMコマンド書き読み・MMU/cache・コア間PSRAM転送 | 識別失敗により未実行 |
| 外部ヒープ、PSRAM上のpool/slab/C allocator | 未登録・未実行。関連カウンタは0 |
| SQLite | **全回未実行**。status=0、sessions=0、queries=0 |
| 最終表示後の監視 | 10秒以上で追加のnative trap/fail markerや再起動は観測しなかった |
| 候補同梱の厳密な判定器 | **全3回不合格**: `incomplete PSRAM discovery or premature memory exposure` |

末尾に `NIHOS_NATIVE_FP_PASS floating=0` が出るが、これはPSRAM/SQLiteの合格を
意味しない。`sqlite 32M image-audit.json physical-device` の判定器は正しく拒否した。
32 MiBは期待する試験条件であり、このnative試験で実容量を検出できたわけではない。
今回はinteger ABIのSQLiteモードなので、RV32Fの実機再検証も含まない。

失敗点はPSRAMのmode-register読み出しと識別の境界まで絞れた。
MR0/1とMR2/3で同じ値が返っており、アドレス送出・DDR設定・タイミングなどの
切り分けが次の作業になる。根本原因やハード故障は、このログだけでは断定できない。
供給レジスタのreadbackも、実電圧や電源投入時の安定性を測定した結果ではない。

## どこまで実装されているか

| 機能 | ソースにあるもの | 確認できている範囲・未完了点 |
| --- | --- | --- |
| 独立native kernel | ROM/stock loader以降のZig/assembly起動、両CPU常駐runtime、CLIC/trap、タイマーpreemption、sleep/exit/reap、イベント、SPSC、IPI/WFI | 今回の実機で基本経路が動作。タスクのメモリ保護や一般的なmigration/サービス基盤の完成は意味しない |
| 内部メモリ | 所有CPUごとのSRAM arena、独立stack領域、guard、使用量・配置監査 | 今回の実機で関連レコードを確認 |
| 外部PSRAM | native供給設定、mode読出し、設定・コマンドI/O、全容量MMU設定、cache同期、コア間検査、再利用buddy heap | 実装あり。従来記録はエミュレータ検証。今回の実機は識別で失敗し、外部メモリ利用には到達しない |
| タスク所有メモリ | 終了時の遅延回収、monotonic pool、slab、size-class pool、C向けmalloc/free/realloc相当と所有者識別 | 候補に実装あり。外部メモリを使う経路は今回未実行 |
| Flash利用 | loaderがマップした読取専用表、許可した起動関数、SQLiteコード・定数のFlash配置、配置・命令監査 | 起動コードと診断表は実機到達。SQLiteのFlash上実行PCは未確認。一般的なFlash書込み・cache停止調整ではない |
| SQLite | 最小C runtime、所有者を固定したメモリDB、SQL長/結果/メモリ枠/実行量の制限、取消API、2セッション26文のnative起動fixture | 候補パッケージではhost/ESP-EMUで成功。今回はSQLite自体を実行できず、実機合格なし。スケジュールされたSQLサービス/RPCは未実装 |
| 画面・タッチ・DMAコピー | 別のESP-IDF-hosted版に、BSPを使う表示・vsync・タッチABI・GDMAコピー試験 | 既存の実機測定記録あり。今回の独立nativeイメージは画面・タッチを初期化しない |
| SDMMC / microSD | **nihOSのドライバ、初期化呼出し、ブロックI/O経路なし** | 未実装。ESP-IDF/BSPに機能が存在してもnihOSへの接続を意味しない |
| ファイルシステム / 永続DB | 本番VFS、FAT/littlefs等への接続なし | 未実装。SQLiteのno-I/O VFSはファイルopen/pathを拒否。SD保存・再起動後読出し・電源断回復はできない |
| Wi-Fi・エディタ・MicroPython/ulab・AI支援・Quake | 設計・調査・構想 | この候補の利用可能な機能としては実装されていない |

主要な実装根拠は候補内の `src/platform/native/`、`src/arch/riscv32/native_tasks.zig`、
`src/soc/esp32p4/psram.zig`、`src/kernel/`、`src/services/sqlite_session.c`、
`probes/sqlite/noio_vfs.c`、`compat/espidf/platform.c`。
SD関連は `src`、`compat`、`include`、`ports` の実装・呼出しを検索して確認した。
設計文書や古いREADMEの説明より、対象revisionのコードと今回の実行結果を優先した。

## 保存先と次の検証点

- [実機ログ・JSON結果・採取スクリプト・書込み記録](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-native-sqlite-physical-test)
- [構造化した全3回の結果](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-native-sqlite-physical-test/physical-results.json)
- [元の候補とmanifest](/Users/masanork/Documents/Codex/2026-10-26/nihos-zig-users-masanork-repo-nihos/outputs/nihos-tab5-native-sqlite-candidate)
- [書込み前Flash全量バックアップ](/Users/masanork/repo/nihos-device-backups/20261026-before-native-sqlite-ed3e34f.bin)

バックアップSHA-256:
`d3a291f05d13a94d114c2b6b0b6dc32aee6f822b3b7ec02b0fcbd88c6ccde300`。
実機には試験した候補を残している。画面が初期化されないのはこのイメージの仕様。
不合格の候補を変更して合格扱いにすることはせず、元イメージと失敗ログを保存した。

次はPSRAM識別処理を修正・実機確認し、MMU/cache・外部ヒープ・SQLite 26文と
完全回収へ進む。電源断起動、反復SQLの耐久性、永続ストレージ、native表示、
公開後のCIはそれぞれ別の未完了項目として残る。
