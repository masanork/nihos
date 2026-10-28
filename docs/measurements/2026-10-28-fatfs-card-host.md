# 読取り専用の実カード経路と候補監査

2026-10-28、実装`0470e59`。新しいSD session、volume probe、選択viewのdisk bind、
guarded FatFs mount、file prefix read、FS/disk/session終了、broker回収を接続した。
[構造化結果](2026-10-28-fatfs-card-host.json)と[host生結果](evidence/2026-10-28-fatfs-card/host-results.json)を保存する。

hostのFAT12/16/32・MBR FAT32・exFAT各fixtureで、同じC経路の正常readを各3回、
sector callbackの1/2/3番目でのI/O失敗を各1回実行し、再bindして正常readへ戻れることを確認した。
workspaceはhostで25,584 B、nativeでは32 KiBのbroker課金・pinを使う。
ASan/UBSan、既存74 Backend/VFS/RPCシナリオ、volume契約53ケースと検査改変5例も通過した。
Pythonは234件。採取checkerはorphan、source不一致、CRC不一致、回収不足やstack guard不足を拒否する。

候補は`NIHOS_NATIVE_FATFS_SD=1`付きのnative imageで861,104 B。
ELF/image、loader/cache profile、source map、resident通知とstatic frameを監査した。
新しい経路はCPU0 bootstrap stackで動き、32 KiBのbulk workspaceをtask stackへ置かない。
静的call-chainは未提供frameとcallback / ROM境界を残しており、総stack資格は付けない。
実行時のpaint/guardも別recordへ記録する。

物理採取では既存littlefsカードで従来試験と組込みFatFs試験を終えた後、SD I/Oを止めて交換待ちに入る。
operatorの交換確認があるまで新sessionを開始しない。交換後はroot直下の非empty、1 MiB以下の通常fileを
最大64 entryから1つ選び、最大4 KiBのprefixを2回読んでCRCを比較する。
これは同じprefixの自己整合性であり、外部content oracleとの一致ではない。
実カードのnative VFS/RPC、取消・強制終了の再検証、永続SQLiteや書込み・電断資格も含めない。

試験後はFlash16 MiBを復元・全面照合する。別カードが挿さったまま元firmwareを起動しないため、
ROM download状態を保ち、元カードへ戻ってからresetする。
初回の採取開始は既存serial ownerを検出してFlash command前に停止した。そのprocessの終了とport解放を確認後、
同じ固定candidateで新規出力directoryへ再実行した。
この文書とhost結果だけから実カードの成功を主張しない。物理結果は別記録とする。
