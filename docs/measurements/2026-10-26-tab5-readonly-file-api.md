# Tab5 read-only file backendと固定workspaceの実機検証

後続の[native storage owner taskとcopy型RPCの実機検証](2026-10-26-tab5-storage-owner-rpc.md)も参照。

2026-10-26。前段のlittlefs boot fixtureから、ファイル操作を独立したbackendへ切り出した。
**APIを使った既存ファイル読取り、owner解放・古いhandleの拒否、workspace消去を実機3起動で確認した。**
実行ソース `0044861`、ブランチ `codex/tab5-psram-physical-fix`。
本段階はtrusted backendとboot clientの検証。アプリ向けtask/IPC/syscallの公開は未実装。

## 実装

[C header](../../include/nihos_storage.h)は`stat/open/read_at/close/release_owner/unmount/destroy`を定義する。
実装は`src/services/storage_littlefs.c`、設計は[ADR 0043](../adr/0043-fixed-memory-readonly-file-backend.md)。
unmodified littlefs v2.11.3の`LFS_READONLY` / `LFS_NO_MALLOC`は維持した。

- mutable state、config、cache、path、fileは全てcaller-owned workspaceに置く。
  file configもworkspace内に保持し、open後の寿命を保証する。
  native版は既存PSRAM予約window 0の`0x48001000..0x48003000`を固定使用。
  mapping検査のsample、peer handoff語、general heapと重ならないことをhost検査する。
  PSRAM mapping成功後だけ利用し、試験後は8 KiB全体のゼロ化を確認する。
- 実使用はRV32で3,248バイト。workspace予約は8,192バイト。
  SD DMAは従来の内部SRAM staging/descriptorを使用し、CPUコピーでPSRAMへ渡す。
- full-cardの512/4096バイトFS blockをupstream metadata検証で判定する。
  pathは最大255バイトのcanonical absolute path。NUL、制御文字、`.`/`..`、
  重複slash、root以外の末尾slashを拒否する。
- 1 sessionにつきopen fileは1つ、readは最大512バイト。offsetはEOFまで。
  tokenと非ゼロownerを検査し、close/owner release後は古いtokenを拒否する。
  token番号が尽きたらwrapして再利用せずopenを拒否する。
- 各API操作は最大8,192 sector reads。boot fixture全体にも8,192回の上限を設定。
  IO/metadata異常後はsessionをpoisonして追加readを拒否し、cleanupは受理する。
  argument不正やfile不在ではsessionをpoisonしない。
- write/format APIはない。ELF監査はwrite系littlefs関数の非存在、
  新API関数のFlash spanとobject/source/headerのhashも確認する。

owner IDはtrusted callerが渡す値で、native task identityやresource tableにはまだ結びついていない。
試験ではowner 1/2を使う。callerは処理とcontroller所有を直列化する必要がある。
同じworkspaceを再初期化する前には古い利用者を停止させる。
このAPIは未検証pointerを受け入れるuntrusted syscallではなく、request/completion ABIでもない。

## 実機結果

ESP32-P4 rev1.3 / PSRAM 32 MiB / `/dev/cu.usbmodem101`。
ICカード検知作業の間はポート利用を止め、ユーザーの再開指示後に再確認した。
当時のloader/appは前段画像とdigestが異なっていた。ユーザーの上書き指示に従い、
監査に使う既知loaderを`0x2000`へ再設定し、各試験appを`0x10000`へ書き込んだ。
tableは前段と一致し、書き換えていない。merged imageによる全領域書込は行っていない。
最初の3起動はPASSしたが、終了時の照合でloader/appが再び異なる画像になっていた。
この状態変化の書込み元は特定していない。その一式は失敗した終了照合と併せて保存し、
最終資格確認とは区別した。
改めて既知loader/appを書込み、同一のexclusive serial descriptorを一度も閉じず、
開始前照合→3リセット→終了後照合を実施した。以下の最終結果はこの連続占有試験。
`exclusive-qualification.py`はesptoolに既存serial objectを渡し、capture中も同じFDを保持する。

| 判定 | 全3起動とIDF比較版で一致した結果 |
| --- | --- |
| FS | 4,096 B × 3,858,432 blocks、SD 30,867,456 sectors |
| ルート列挙 | 4項目（file 3、directory 1）、digest `40e9d8c6` |
| 選択ファイル | 10,752 B、CRC32 `883551bf`、名前digest `33445ceb` |
| mount→全読取り→unmount | 2回、結果一致 |
| open / close | 各4回（owner releaseによるcloseも含む） |
| owner解放 | 2回 |
| 拒否 | wrong owner、513 B要求、解放後read、再open後の旧token close、計8回 |
| read_at | 46回。全データ、EOF、先頭への戻りを含む |
| FS用sector read | 188回（geometry判定、metadata、API確認を含む） |
| 作業領域 | 8,192 B全体を消去確認 |
| program/erase/sync callback | 呼出し0 |

ファイル名・内容は出力せず、digest/サイズ/CRCを記録する。
全ファイル・全階層の検査ではない。CRC/digestは暗号学的な同一性保証ではない。
IDF比較版は同じFSライブラリ・backend・fixtureを使い、独立したSDK block IOで読む。
別実装のFS parserとの比較ではない。

各起動は先にSDMMCを1ビット400 kHz→4ビット400 kHz→4ビット20 MHzへ切り替え、
計3,096回の固定・分散読取りも実施した。1,024地点digest `524262a3`は全段階でIDF版と一致。
その後FS用188回、**計3,284読出し/起動、3起動で9,852読出し。SD sector書込は0。**

| 起動 | 採取秒数 | 最終PASS後の監視秒数 | FS stack観測値 | SQLite stack観測値 |
| --- | --- | --- | --- | --- |
| 1 | 37.336 | 10.165 | 6,336 B | 6,056 B |
| 2 | 37.369 | 10.198 | 6,336 B | 6,056 B |
| 3 | 37.354 | 10.184 | 6,336 B | 6,056 B |

全3起動で通常300ラウンド、両CPU、timer、IPI/idle、PSRAM mapping/coherence、heap回収、
SQLite 2セッション26文も通過した。SQL前後の空きは16,022,848バイトに回復。
追加trap/fail・再起動なし。これらはUSB RTSリセットで、cold bootの証拠ではない。
前段のPSRAM全ワード検査やSQL 1,000バッチは今回は無効。

## メモリの変化

| 項目 | 前段 `fbbce97` | 最終 `0044861` |
| --- | --- | --- |
| 内部heap | 49,856 B | 52,288 B（+2,432 B） |
| 48 KiB linker最低値に対する余裕 | 704 B | 3,136 B |
| FS fixture stack観測値 | 6,752 B | 6,336 B |
| SQLite fixture stack観測値 | 7,112 B | 6,056 B |
| app | 750,144 B | 752,896 B |

初期API画像はFS stack 6,912 B、SQL 6,472 Bで合格したが、FSは前段より160 B増えていた。
その画像も保存した。その後PSRAM診断、SD診断、SQL診断をそれぞれnoinline関数へ分離し、
一時report/log用stack予約を後段へ持ち越さないようにして最終値を確認した。
8 KiB枠のguardと160 B trap枠を差し引くと、観測上の余裕はFS 1,680 B、SQL 1,960 B。
固定fixtureの走査値であり、任意FS/SQL操作やcall graph全体の最大保証ではない。
fixture操作自体も追加しているため、同一バイナリ/同一操作列の性能比較ではない。
所要時間や20 MHz設定から速度向上を主張していない。

- app SHA-256: `fa38bd0bd8491e91577aba0db8f757c2170b52c32d3d95ecbaba7db466e8c34d`
- ELF SHA-256: `96a2180a747370af56f1c72af8fa3b488509508cd9ff5f97e119977d320b4642`

## 回帰検査・保存

- Zig Debug / ReleaseSafe: 各160件。workspaceと予約windowの境界検査を追加。
- Python evidence checker: 113件。image/API/workspaceの誤結合、未消去、close/release不足、
  古い/欠落した結果を拒否する検査を含む。
- ASan/UBSanのhost FS/API試験は512/4096両geometryで合格。
  canonical path、不正owner、busy、跨sector offset、短い末尾read/EOF、ゼロ長、
  不正buffer/size、owner解放、stale token、token枯渇、IO poison/予算上限、消去と外側guardを検査。
  IO失敗・容量不一致・両superblock破損も維持し、既知1,300 BデータのCRCはPython zlibで別計算。
- formatting / ZLint / ShellCheck / RV32 architectureと6 native ELFリンク監査が通過。
- 通常ESP-EMU SQLite 32 MiB / integer PSRAMなしも通過。SD/FS自体のemulation試験ではない。
- [固定画像・独立block IO比較・初期画像・全ログ・license・hash manifest・source patch](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-readonly-file-api-qualification)

最終画像を本体に残した。mainのdirty作業は変更せず、push・remote CIは実行していない。
ビルドと判定コマンドは前段の[read-only FS報告](2026-10-26-tab5-littlefs-readonly.md)と同じ。
新APIとworkspaceの証拠はimage manifestの`api_version=1`に結び付け、判定器が自動要求する。

次はstorage owner taskとrequest/completionを接続し、task終了時のhandle回収と
runtime向けの独立timebaseを実装する段階。現SD controllerはboot専有でscheduler timerを借り、
controller全体を初期化する。動作中アプリからの呼出し、C6 Wi-Fi/slot 1共存、
partition内FS、FAT/exFAT、SD書込、永続SQL VFS、hot removal・電源断回復は未対応。
