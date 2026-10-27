# Tab5 native SDMMC: 4ビット・20 MHzの実機読取検証

後続の[read-only block APIとlittlefs読取りの実機検証](2026-10-26-tab5-littlefs-readonly.md)も参照。

2026-10-26。USB再接続後、前段の1ビット・400 kHzから段階的に広げた。
**4ビット・20 MHzまでの切替と読取を実装し、同一最終画像で3起動合格した。**
実行ソースは `971ff11`、ブランチは `codex/tab5-psram-physical-fix`。
これはread-onlyのboot fixtureであり、runtime storage serviceやfilesystemではない。

## 再接続・電源・書込み対象

- Tab5 / ESP32-P4 revision 1.3、Flash 16 MiB、PSRAM 32 MiB。
  ポート `/dev/cu.usbmodem101`、MAC `e8:f6:0a:e2:e8:9c`。
  操作前にserialの他所有者がないことを確認した。
- 再接続直後のloader/table/appは、前段の最終画像とesptoolで全て一致した。
- ユーザーから「本体をOFF→ONした。移動したので」と報告あり。
  **その電源投入時のログは採取していない。以下の3回は電源保持のUSB RTSリセット。**
  本体のcold bootをログで資格確認したとは扱わない。
- 独立IDF oracleとnative appは、いずれもapp領域 `0x10000` だけを書き換えた。
  元loader/tableを保持し、終了時に3領域をesptoolで再照合した。
  native画像のSRAM配置監査にも、実際に保持したloader ELF/configを指定した。
- SDへのsector書込・消去・formatは実行していない。ACMD6によるbus幅の変更は
  volatileな通信設定。既存Flash全量バックアップとdirtyなmain作業ツリーは保持した。

## 実装と段階別の判定

`src/soc/esp32p4/sdmmc.zig` のcontrollerに以下を追加した。

1. 既存の1ビット・400 kHzで初期化、host幅とdividerのreadbackを確認。
2. CMD55のAPP_CMD応答を検査し、ACMD51でSCR 8バイトを固定内部DMAへ読む。
   SCRの形式と1ビット・4ビット対応を検査する。
3. CMD55→ACMD6(arg=2)成功後にD3をSDMMCへ接続し、host側も4ビットへ変更。
   host幅のreadbackを要求する。
4. clock停止→divider変更→clock再開。それぞれupdateを実行し、divider=1とenableを確認。
   retained host clock 40 MHzから20 MHzを設定する。

初期化・転送は有限poll、固定内部SRAMの512バイトbufferと64バイトdescriptorを使う。
SCRは8バイト転送だけを許可し、sector読取はCMD17の512バイトだけを許可する。
幅・clock切替が途中で失敗したcontrollerも再利用不可にする。
コマンドallowlistは `0,2,3,6,7,8,9,13,17,41,51,55`。
sector書込・消去系コマンドは許可しない。割込み・動的確保・RTOSは使わない。

| 段階 | bus | clock設定 | host width readback | divider | sector読出し/起動 |
| --- | --- | --- | --- | --- | --- |
| 0 | 1ビット | 400 kHz | 0 | 50 | 1,032 |
| 1 | 4ビット | 400 kHz | 1 | 50 | 1,032 |
| 2 | 4ビット | 20 MHz | 1 | 1 | 1,032 |

各段階で先頭・次・中央・末尾の4セクターを2回読む。それに加え、
`index * (sectors - 1) / 1023` のLBAを1,024地点読む。
各sectorのCRC32とLBAをlittle endianでFNV32にfoldし、段階間の一致を要求する。
全sector走査ではなくサンプリングであり、この32ビットdigestは暗号学的な同一性保証ではない。
20 MHzは設定とregister readbackによる値で、実信号の周波数測定や帯域benchmarkではない。

## 独立IDF版との比較と3回の最終実機結果

`probes/sdmmc/oracle/` のIDF host/protocol/DMAで、同じカードを4ビット・20 MHzで読む。
cardの実際のbus幅・clockもSDKから取得してログに出す。これはFreeRTOSを使う比較アプリであり、
native実行の証拠とは別。filesystemはmountしない。

- 検出容量は両実装とも30,867,456セクター。
- LBA `0`, `1`, `0x00eb8000`, `0x01d6ffff` のCRC32は順に
  `9022e83d`, `bd7bc39f`, `c6d765f6`, `c6d765f6`。
- 分散1,024地点のdigestは、独立IDF版とnative全3段階・全3起動で **`524262a3`**。
- 最終native画像は1起動3,096読出し、3起動合計9,288読出し。sector書込は0。
  IDF版は別に1,032読出し。容量、固定LBAの順序・反復、CRC、分散digestをcheckerで照合した。

| 最終画像の起動 | 採取秒数 | 最終PASS後の監視秒数 | SDMMC＋native/SQLite | SQL stack観測値 |
| --- | --- | --- | --- | --- |
| 1 | 37.154 | 10.139 | 合格 | 6,968 B |
| 2 | 37.151 | 10.138 | 合格 | 6,968 B |
| 3 | 37.126 | 10.112 | 合格 | 6,968 B |

全3起動とも、通常のnative 300ラウンド、両CPU、PSRAM mapping/coherence、timer、
IPI/idle、heap回収、SQLite 2セッション26文まで判定した。追加trap/fail・再起動はなかった。
今回の画像では、前段のPSRAM全ワード検査・SQL 1,000バッチは有効にしていない。
SQLite前後の空きは毎回16,022,848バイトに回復した。
8 KiB bootstrap枠のguardを除くstack残りは1,208バイト、160バイトtrap枠を差し引くと1,048バイト。
固定fixtureの走査観測値であり、任意SQLや全call graphの最大stack保証ではない。

最終appは741,696バイト、内部heapは53,568バイト。実機にはこの画像を残した。
画面・タッチは初期化しない。

- app SHA-256: `d509fd90c54715f04232f7f5510aba43721ef32aa1d876b8acdd8c21bf45feea`
- ELF SHA-256: `47602a6b9f2e6534f6cb526245997a7e01617e6c4e3a1df889031cef42b5b617`

再接続時の旧baselineは1起動合格。分散走査を追加する前の24読出しの予備試験も保存したが、
上表の最終画像・3起動とは区別している。

## 回帰確認・再現

Zig Debug / ReleaseSafe各157件、Python native判定器106件、formatting、ZLint、ShellCheck、
RV32 architecture契約と6 ELFリンク監査が通過した。SCR/APP_CMD拒否、host幅/dividerの
readback不一致、2 TiBのLBA境界、段階・分散走査の欠落/不一致も検査する。
通常ESP-EMU SQLite 32 MiBとinteger PSRAMなしも通過。
**エミュレータではSDカードを検証していない。リモートCIは実行していない。**

```sh
# profile 0(default)=1 bit/400 kHz, 1=4 bit/400 kHz, 2=4 bit/20 MHz
NIHOS_NATIVE_SDMMC=1 NIHOS_NATIVE_SDMMC_PROFILE=2 sh tools/build-native.sh device sqlite
python3 tools/check-native-log.py BOOT.log REPORT.json sqlite 32M IMAGE-AUDIT.json physical-device sdmmc-fast
python3 tools/check-sdmmc-oracle.py ORACLE.log REPORT.json COMPARISON.json
```

画像を固定し、その画像の監査結果を使って判定する。実機監査のloader指定は前述の通り。
通常ビルドのSDMMC無効、SDMMC有効時のprofile 0という既定値は維持した。

- [最終画像・独立oracle・全ログ・監査・source patch・SHA manifest](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-sdmmc-wide-qualification)
- [前段のPSRAM/FP/SQL反復とPIO失敗の記録](2026-10-26-tab5-hardware-qualification.md)

次はread-only block API、カード形式判別、read-only filesystem。
その前後で未挿入・異常応答・再試行方針の実機試験も必要になる。
現状はboot専有でcontroller全体を初期化する。C6 Wi-Fi/slot 1との共存には所有・仲裁の設計が必要。
SDSC、複数sector、PSRAM向けDMA、runtime storage service/RPC、SD書込、永続VFS、
電源断回復は未実装。mainへの反映・pushは行っていない。
