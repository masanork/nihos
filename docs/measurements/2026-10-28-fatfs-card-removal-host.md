# Card抜去・transport失敗のhost結合

2026-10-28、source `fa05531`。SD ownerからC disk bridgeへ渡すfenced read結果で、
汎用I/O失敗・取消・抜去を区別するようにした。以前は全て-1へ変換していた。
[構造化結果](2026-10-28-fatfs-card-removal-host.json)と
[host/target監査の生結果](evidence/2026-10-28-fatfs-card-removal-host/)を保存した。

|経路|確認した動作|
|---|---|
|transport取消 -2 とRPC取消通知|replyは-125、全data clear、mountはfaulted|
|transport抜去 -3|diskとVFS mountはremoved、replyは失敗で全data clear|
|I/O間のcard_remove|cached FILで読めるprefixも拒否し、新しいsector callbackを発行しない|
|以後の操作|旧fileのreadとrootからのopenを拒否、不健全なmountへのclient rebindも拒否|
|終了|client停止後にendpoint/FSを終了し、parent clear/unpin/freeと全pool回収|

`nih_fatfs_card_remove(context,generation)`はtrusted ordinary owner専用である。
旧世代を拒否し、同世代の再通知を許す。context/Backend/pathは回収のため保持し、
callback中のdestroyとservice parentのretireを拒否する。IRQから直接呼ぶAPIではない。
同じaddressに新世代をmountした後も旧通知を拒否することを確認した。

FAT12/16/32・MBR FAT32・exFATの各fixtureで、新しい3経路を含む全99シナリオが通過した。
CはASan/UBSan、実Zig VFS/RPCとdevelopment brokerはReleaseSafeで実行した。
別のcard契約試験ではcached readとcallback中の抜去も検査した。
低層disk契約は4種類の非zero結果を8個のsector位置それぞれで返し、途中のscratchが
callerへ公開されないことと、未知の結果もI/O failedとして拒否することを確認した。
全fixtureの前後hashが一致した。

旧実装`372c510`のdisk bridgeを使って同じ試験を再実行すると、低層のremoved state検査と、
実RPC mountのremoved state検査がそれぞれ失敗した。この2件を負例として保存した。
修正版の全99シナリオのsource指紋は、直接46ファイル、disk試験の24ファイルとも一致した。

RV32 C contextは26,104 B、service parentの使用44,928 B・課金65,536 B、clientの別課金8,192 Bを維持する。
native SD RPC構成もELF/frame・image監査を通過した。imageは850,880 B。
source archive、image/ELF、loader、manifestをprivate buildへ固定した。
SD card phaseを使わない従来の組込みFatFs RPC構成も、回帰ELF/frame監査を通過した。
これは既存のSD RPC workloadでerror-result bridgeをcompile/linkした監査であり、
新たなmounted-card abortの実機採取候補ではない。card_remove APIはRV32 compileとhost実行までである。
Python236件、Zig Debug/ReleaseSafe（cache）、変更したZig 2ファイルのfmt/ZLintも通過した。

今回のtransport結果とRPC取消通知はhostから別々に注入した。
native RPCの取消からcontroller stopへの自動中継、card-detect IRQ登録、silicon上のDMA beatの観測、
mount中の実カード抜去は未確認である。未確認DMA fenceを通常の失敗として返す経路は追加していない。
この段階では実機へのFlash書込みやresetを行っていない。
前回の[実exFAT VFS/RPC合格run](2026-10-28-fatfs-card-rpc-physical.md)を、今回の失敗経路の資格へ転用しない。
