# 電源キー操作後の起動確認と、未成立のclean power-on gate

2026-10-27。実カードの抜去・再挿入は[別試験で合格済み](2026-10-27-sd-removal-physical.md)。
ここではバッテリーとUSBを接続したTab5の電源キーを操作し、USB消失後の復帰を調べた。
最終候補の通常USB reset起動3回と、電源キー操作後のnative workloadは成功したが、
ROM APIから得た起動理由が`0x07`だったため、要求していた`0x01`のclean power-onは不合格とした。

[構造化証跡](2026-10-27-sd-cold-power-inconclusive.json)に候補hash、operator確認、成功した通常起動、
不合格になった電源投入判定、全先行試行と復元の記録を保存した。判定条件を緩めて成功扱いにはしていない。

## 最終候補と確認範囲

firmwareは`c6e3190`、host runnerは`29cb736`。
appは821,904 B、SHA-256 `781686c2563d3deb809cbd4ffb244eabeb866ce97bfef17fe5998ac06e9e08ae`。
residentは105,920 Bで、112 KiB枠内の余裕は8,768 B。
Tab5はESP32-P4 rev1.3、MAC `e8:f6:0a:e2:e8:9c`、PSRAM 32 MiB。

|確認|結果|
|---|---|
|同一候補のUSB reset起動3回|全回合格、起動理由`0x17`|
|operatorの電源キー操作|短く2回、USB消失を確認、5秒以上待って1回|
|復帰時の起動理由|`NIHOS_NATIVE_RESET cpu0=00000007 ack=00000001`|
|復帰後のworkload|SMP・SD・littlefs/storage owner・memory-only SQLite・broker・取消/抜去通知試験に合格|
|clean power-on gate|期待値`0x01`に一致しないため不合格|
|終了時のFlash|試験直前の内容へ復元、16 MiB全体のdigest照合に成功|

起動理由の意味は固定SDKの[reset_reasons.h](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/include/soc/reset_reasons.h)に照合した。
`0x01`はchip power-on、`0x07`はMWDT core reset、`0x17`はUSB Serial/JTAG UART resetである。
電源キー操作でUSBが消えたことと、chipの起動理由がpower-onだったことは同一の証拠として扱わない。

## 取得経路で修正したこと

最初の試行ではUSBの再openに伴うリセットが入り、別の試行ではMacがportを認識する前のログが欠けた。
host側は再open時にDTR/RTSを操作せず、受信済みboot bytesをflushしないcapture adapterへ変更した。

それでも最初のROM logは欠け得るため、opt-inの`NIHOS_NATIVE_COLD_CAPTURE=1`を追加した。
機器は固定ROM ABI `rtc_get_reset_reason(0)` (`0x4fc00018`)を先に読み、
PCからの`G`を待った後に保存した理由と全native logを出す。待機はTG1の1 MHz counterで120秒に制限する。
ROM APIのaddress、USB RX helperのresident配置、追加source hashをimage監査へ含める。
ROM headerが欠けた場合でも、固定source/imageに結び付いた機器側recordで判定し、watchdog値は拒否する。

この待機markerはCRLFだったが、runnerがLFだけを探してACKを送らない不具合も見つかった。
実際のwire bytesを[回帰fixture](../../tools/fixtures/cold-capture-crlf.json)へ保存し、改行を正規化して判定するよう修正した。
さらに切断後も`is_open`がtrueのまま残るdescriptorに対し、例外chainのerrnoを見て閉じ直す復元経路を追加した。
自動復元に失敗した試行は、別FDで機器IDを確認してから復元し、Flash全体を再照合した。

## 分かったことと分からないこと

待機を始める前にTG0のflash-boot MWDTを停止する順序へ変更したが、その前後の両候補とも`0x07`を記録した。
この順序変更だけで原因が解決した、あるいは接続待ちだけが原因だったとは主張しない。
起動理由はcapture entryで既に保存されており、どの段階でwatchdog resetに至ったかの切り分けは残っている。

`0x07`の実ログも[回帰fixture](../../tools/fixtures/cold-watchdog-reset.json)に保存した。
通常のstartup recordとして読めても、clean power-onとしては拒否するテストを追加した。
host coreはZig Debug / ReleaseSafe各198件、Pythonは183件、format / ZLint / ShellCheck、
既存6種類のnative ELFと今回の候補監査が成功している。

USBと背面バッテリーの両方を外した給電断試験は、operatorが現時点では実施困難なため行わなかった。
以後の電源・カード操作は要求せず、clean power-onは未確認として残す。
silicon上の停止/cache失敗注入と、FatFs Backend / VFS / RPCの接続も今回の合格範囲には含めない。

最終復元の退避ファイルSHA-256は`a7385ecc9562578c8d84286e300f77040c76f2bbd54c79117f4f02d1f37dd8e5`。
[最終候補とraw archive](/Users/masanork/Documents/Codex/2026-10-27/nihos-cold-watchdog-fixed-candidate)の
`power-physical-6`にprivate backupと照合logを保存した。backup本体を公開artifactへ含めない。
復元時の内容一致は確認済みだが、その後の電源状態や他セッションの書込みまで固定する記録ではない。

## 次回に備えた診断追加（実機未検証）

後続のhost作業で、nativeがWDTやtimerを初期化する前のreset snapshotを追加した。
LP / HP0 / HP1の理由とflag、生のcause word、ROM保存PC 2語、TG0 / TG1のclock gateと
clock有効時だけのWDT config0を保存し、host ACK後にformat 2の固定recordへ出力する。
保存PCの有効性と直前resetへの対応は未保証で、ROM / loader内部での停止位置を確定する情報ではない。

[検証記録](2026-10-27-native-reset-snapshot-host.json)の候補はimage 822,048 B、resident 106,176 B。
112 KiB枠の余裕は8,512 B、既存配置policyのresident上限106,496 Bまでの余裕は320 Bである。
Zig Debug / ReleaseSafe各200件、Python 184件、format / ZLint / ShellCheck、
既存6構成のELF監査と新候補のimage監査が成功した。
追加の機器操作や書込みは行っておらず、`0x07`の原因とclean power-on gateは引き続き未解決である。
