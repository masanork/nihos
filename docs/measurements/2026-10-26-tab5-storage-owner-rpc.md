# Tab5: native storage owner taskとcopy型RPCの実機検証

2026-10-26。実行ソース `a009310`、ブランチ `codex/tab5-psram-physical-fix`。
**CPU1のnative client taskからCPU0のstorage owner taskへ要求を送り、
既存ファイルの全読取りと、open handleを残した通常EXIT後の回収を3起動で確認した。**
これはopt-inの2タスク資格試験。一般アプリ向けmulti-client service/syscallの完成ではない。

## 追加実装

- [ADR 0044](../adr/0044-native-storage-owner-and-copied-rpc.md)に従い、既存SMP/IPI試験の
  全workerが終了・回収された後、各CPUのlifecycle stackを新しいnative taskで再利用する。
  CPU0がSD/littlefsを専有し、CPU1がclientとなる。各task stackは4 KiB。
- `src/kernel/storage_rpc.zig`: 容量2のSPSC request/reply queue、sequence照合、
  reply credit確保、endpointの終了処理。要求にowner IDやpointerは含めない。
  path/metadata/dataを固定長でコピーし、1 readは最大512バイト。
  root listing、stat、open、read-at、closeを配送する。
- endpointはkernelが作ったtask handle/generationと、task内で取得したruntime C identityに結び付ける。
  今回のclient identityは`0x01010003`（CPU1、slot 1、generation 3）。
  ownerの値をclient messageから受け取らない。
- queue publish→resident atomic flag→IPIの順で通知する。IRQはflagsとscheduler policyだけを扱い、
  PSRAMのqueue payloadやFSには入らない。queue stateを再確認してからevent待機する。
- clientのEXIT trapで一致するhandleのtombstoneを公開し、owner taskがfile releaseを実行する。
  kernelのallocation cleanupとstorage cleanup acknowledgementが完了するまでreapを待つ。
  FS操作をIRQ stack上では行わない。
- FS workspaceは既存の`0x48001000..0x48003000`、IPC/scratchは
  `0x48004000..0x48006000`。どちらも既存PSRAM予約window内でgeneral heapから分離。
  SD DMAは内部SRAM staging/descriptorを維持し、PSRAMへはCPUコピーする。
- TG0の2チャネルは両scheduler用のまま。専有TG1.T0をboot時にXTAL 40 MHz / 40、
  alarm/IRQなしのcounterとして設定し、source/divider/enableをreadbackする。
  group watchdogも明示的に扱う。runtime SD waitはこのcounterを使い、scheduler timerを止めない。
  bootで初期化したhealthyなSD controllerを引き継ぎ、runtimeではhost reset/power cycleを行わない。
- `storage_runtime.zig`を独立したZig objectにし、text/定数は既存SQLite Flash spanへ配置。
  mutable atomicsとIRQ hooksは内部SRAM。object関数/hashをmanifestへ加え、
  auditでIRQ entryのSRAM配置を要求する。これは構造検査で、call graph全体や隔離の証明ではない。

## 実機の要求・終了処理

実機はESP32-P4 rev1.3 / Flash 16 MiB / PSRAM 32 MiB、`/dev/cu.usbmodem101`。
他プロセスがportを使用していた場合は解放を待ち、強制終了していない。
同じexclusive serial objectを保持したまま、fresh IDF referenceの実行、既知loader/native app書込、
開始前照合、3回のUSB RTSリセット、終了後照合を行った。
ユーザーの上書き指示に従いloader/appを書き込み、partition tableは保持した。

各回、boot段階のSD 1ビット400 kHz→4ビット400 kHz→4ビット20 MHzと分散1,024地点、
通常の300ラウンドSMP/PSRAM/heap、64往復IPI/idleを完了後に新しい2タスクを開始した。
旧busy workerは終了済み。TG0のperiodic alarmは旧IPI phaseからdisarmのままで、
新serviceはその設定を変更しない。以下はevent駆動の2タスクとbootstrapの動作であり、
ゲーム/描画/Wi-Fiとの同時実行や任意CPU0 workerのpreemption試験ではない。

| runtime判定 | 全3回の結果 |
| --- | --- |
| 受理・応答したrequest | 38 / 38 |
| backendへ渡した有効operation | 36（不正sizeと不明opcodeの2件は手前で拒否） |
| request queue full | 1回を意図的に作り、3件目の非受理を確認 |
| 拒否応答 | 5（513 B、未知opcode、invalid handle、close後read、再open後の旧handle close） |
| ファイル全読取り | 10,752 B、CRC32 `883551bf` |
| EOF | 0バイト応答 |
| 通常EXIT検知 / owner release / retired endpointの拒否 | 各1 |
| FS 8 KiB / IPC 8 KiB消去 | 両方確認 |
| task ledger | 各CPU opened 8、closed/completed 7、reuses/stale 4、owned/pending 0 |

clientは一度closeして古いhandleを確認し、再open成功後のhandleを閉じずにreturnする。
そのEXITを受けたownerがreleaseし、FSをdestroy/clearしてからcleanupをacknowledgeする。
両taskのreap後にIPC領域をclearする。bootstrap task自身はliveなのでopenedとclosedには1の差がある。

rootは4項目（file 3、directory 1）、volumeは4,096 B × 3,858,432 blocks。
runtimeで選んだファイルのサイズ/CRCはboot fixtureと一致し、boot fixtureの容量・固定LBA・
分散digest・FS結果は今回取り直したIDF referenceとも一致した。
IDF版は同じFS/backendを独立したSDK block IOから使う。別実装FS parserとの比較ではない。
CRC/digestは暗号学的な同一性保証ではない。ファイル名・内容はログへ出していない。
SD sector write/eraseは行っていない。runtimeのrequest数をsector read数とは扱わない。

| 起動 | 採取秒数 | PASS後監視秒数 | owner処理区間のTG1 counter差 | 同区間のCPU1 bootstrap進行 |
| --- | --- | --- | --- | --- |
| 1 | 37.289 | 10.010 | 106,165 ticks | 4,217 |
| 2 | 37.460 | 10.182 | 106,075 ticks | 4,215 |
| 3 | 37.291 | 10.012 | 106,036 ticks | 4,211 |

counterは1 MHzに設定しているが外部計測器で周波数測定はしていない。
区間はmount、root query、IPC、read、拒否試験、close/clearを含み、file単体の帯域測定ではない。
CPU1進行は同区間のbootstrap poll/yield差分で、別アプリの性能保証ではない。
全3回で後続SQLite 2セッション26文も合格し、heap空きは16,022,848 Bへ回復した。
追加trap/fail・再起動なし。USB RTS起動でありcold boot試験ではない。
PSRAM全ワード検査やSQL 1,000バッチは今回有効にしていない。

## メモリ・失敗の区別

最終appは764,928 B、内部heapは50,176 B。前段の52,288 Bから2,112 Bを使い、
48 KiB linker最低値に対する余裕は1,024 Bになった。一般service拡張には再配置の検討が必要。

| stack | 全3回の観測値 | guardと160 B trap枠を差し引いた残り |
| --- | --- | --- |
| storage owner task / 4 KiB | 3,184 B | 736 B |
| client task / 4 KiB | 1,360 B | 2,560 B |
| boot FS / 8 KiB | 6,336 B | 1,680 B |
| 後続SQLite / 8 KiB | 6,136 B | 1,880 B |

固定fixtureのstack paint観測値であり、任意filesystem/call graphの最大保証ではない。
初期配置はlinkerの48 KiB条件を割り、生成途中のclientには約11 KiBのstatic frameも見つかった。
その画像を実行せず、独立objectのFlash配置とPSRAM scratchへ変更した。
最初の実機画像はruntimeの全成功表示まで進んだが、判定器が追加taskの`stale`台帳値を
旧版の3と比較して終了した。raw logと当時のerrorを保存し、後から正しい4で判定した結果も別保存。
上表の最終3起動は、更新済みの判定器と固定最終画像で開始前/後照合まで完了したもの。

- app SHA-256: `4debfcf6520e3f940e8b52076d50ca1f4760f8249a266c8ceea0143667b4ecd8`
- ELF SHA-256: `f4d37095bfad227db3feb87f17a7f73b03dd652704791e28a166d897682c7b81`

Zig Debug / ReleaseSafe各162件、Python判定器115件が合格。
RPCのcopy lifetime、sequence/replay、malformed message、reply credit、終了後拒否をhostで確認した。
ASan/UBSanのFS/API試験は512/4096両geometryで合格し、root listingの境界も追加した。
formatting / ZLint / ShellCheck / RV32 architectureと6 native ELFリンク監査が通過。
通常ESP-EMU SQLite 32 MiB / integer PSRAMなしも合格。
**SD/FS/新service経路をESP-EMUで実行したものではない。remote CIは未実行。**

## 再現と残り

```sh
NIHOS_NATIVE_STORAGE_SERVICE=1 NIHOS_NATIVE_STORAGE=1 \
  NIHOS_NATIVE_SDMMC=1 NIHOS_NATIVE_SDMMC_PROFILE=2 \
  sh tools/build-native.sh device sqlite
python3 tools/check-native-log.py BOOT.log REPORT.json sqlite 32M IMAGE-AUDIT.json physical-device sdmmc-fast,storage
```

serviceは既定で無効。実機auditには実際に使用するloader ELF/configを指定する。
manifestのservice versionにより、log checkerが追加taskの台帳とservice成功記録を要求する。
[固定画像・fresh reference・失敗例・全ログ・license・patch・hash manifest](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-storage-owner-rpc-qualification)。
検証終了時点で最終画像を書込み・照合した。mainのdirty作業は変更せず、pushは行っていない。

次のgateは、clientの強制終了や未完了requestを伴う取消し、複数client/endpoint、再起動・
再接続policy、同じCPU上の任意アプリとのpreemption。
今回の正常EXITは全reply受信後で、in-flight cancellationは資格確認していない。
taskはmachine-modeの共有address spaceを使い、一般アプリ向けの権限/path分離やsyscall ABIは未実装。
C6 Wi-Fi/slot 1仲裁、hot removal、partition内FS/FAT/exFAT、SD書込、永続SQL VFSと電源断回復も未対応。
