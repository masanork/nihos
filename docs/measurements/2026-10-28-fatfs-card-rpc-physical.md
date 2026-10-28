# 実exFATカード上のnative VFS/RPC

2026-10-28。source `ad8bb03`の固定候補をTab5 / ESP32-P4 rev1.3で1回のwarm USB resetから実行した。
実SDカードのcard contextをnative FSD/client taskとVFS/RPCへ接続し、取消、kernelによるclient停止、
再bind、終了処理まで通過した。[構造化結果](2026-10-28-fatfs-card-rpc-physical.json)と
[生ログ・照合・復元記録](evidence/2026-10-28-fatfs-card-rpc-physical/)を保存した。

|確認|実機結果|
|---|---|
|volume|exFAT、MBR第1partition、開始LBA32,768、長さ247,775,232 sectors|
|device|247,808,000 sectors、各512 B|
|RPC|request 11件、reply 9件、取消1件、kernelによるclient停止1件|
|停止後|queued request/replyを各1件破棄し、replacement clientへ再bind|
|旧識別子|epoch・handle・reply・exitを各1件拒否|
|読取り|140 Bを2回、CRCは両方`0x53974ff0`|
|FatFs disk read|15 sector、volume probeのreadとは別|
|service parent|44,928 B使用、65,536 B課金、client frameの8 KiBは別owner|
|終了|FS destroy、disk detach、世代一致session終了、parent clear/unpin/freeとaccount回収|
|worker stack paint|FSD 2,720 B、停止前/replacement clientの最大384 B、guard保持|

取消・停止の待機点は実SD sector readがDMA fenceを確認して戻った後である。
client停止はCPU1のkernel bootstrapが実行し、旧clientのstack再利用前にもpaintを測定する。
host callbackからのexit通知注入や、前回の直接FatFs readをこの合格runの代わりにしていない。
旧Flash fixture decoderは補助self-checkとして残るが、今回のfilesystem入力は実SD上のvolumeである。

選択fileはroot直下の最初の非empty・1 MiB以下の通常fileで、最大64 entryを調べる。
file名はCRCのみ、内容はbyte数とCRCのみを記録した。反復CRC一致はprefixの自己整合性であり、
外部の既知content oracleとの一致ではない。SQLite永続化はこの試験へ含めない。

候補は850,864 B。別セッションからの実機引継ぎ後にcu/tty両aliasの未使用を確認し、
採取中はkernel排他を含む同一serial FDを保持した。Flash全体16 MiBをprivateに退避し、
loader/partition/appを候補の前後で照合した。候補の前照合後もROM downloadで待ち、
operatorの試験用カード交換確認後だけ起動した。最終PASS後10秒の監視も完了した。

採取済みlogを固定sourceのcheckerで再検査し、保存reportとの一致を確認した。
RPC sourceの改変、parent clear未完了、反復CRC不一致の3負例は全て拒否された。
[host結合・候補監査](2026-10-28-fatfs-card-rpc-host.md)は別の記録として保持する。

試験終了後は変更したerase-aligned範囲を復元し、Flash16 MiB全体が直前snapshotと一致した。
backup本体はrepositoryへ入れていない。元カードへの返却確認までは元firmwareのresetを保留し、
ROM download状態を保つ。

今回の合格は実exFATカード1枚、1回のwarm USB reset、読取り専用の経路に限る。
DMA転送途中のabort、mount中/転送中の実カード抜去、native FAT12/16/32、clean POR、書込み、
SQLite永続化、電断復旧は別gateである。stack paintも通過した経路の観測値であり、
callback/ROM/未提供frameを含む総call stackの上限を証明しない。
