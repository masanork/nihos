# FatFs read-only disk I/O bridgeのhost検証

2026-10-28。`codex/vfs-native-lifetimes`の`41df441`を基点に、FatFs `diskio`と
既存の同期SD sector exportをつなぐadapterを追加した。
実行はhost上の同期callbackと実FatFs、native側はRV32 object compileまでである。
serial接続・Flash書込み・実カードmount・電源操作は行っていない。

[生のJSON結果](2026-10-28-fatfs-disk-host.json)にsource、upstream、RV32 objectのhash、
各fixtureの前後hash、観測値と残る制約を保存した。
再実行は`python3 tools/check-fatfs-disk.py`。CIにも同じ試験とJSONのみの保存を追加したが、
今回記録した成功はlocal実行であり、remote CIの成功ではない。

|対象|結果|
|---|---|
|FAT12 / FAT16|各23 sector read、文字列・日本語名・断片化を確認|
|FAT32 / MBR FAT32|各29 sector read、同じ内容とpartition rebasingを確認|
|exFAT|91 sector read、断片化と4 GiB超fileの3か所のmarkerを確認|
|read-only|全5 imageの全体SHA-256が前後一致、FatFs write APIなし、write stubは拒否|
|設定誤りのnegative control|write可能なFatFs設定ではadapterのcompileを拒否|
|途中失敗・失効|4 KiB内の8個全てのsector位置で、出力不変と後続I/O拒否を確認|
|admission|範囲外・4 KiB超・budget不足・再入・古いepoch・epoch再利用を拒否|
|64-bit算術|2 TiB deviceの最終sectorを32-bit callback LBAへ正しく変換|
|sanitizer|host ASan / UBSanで診断なし|
|native向けcompile|disk layerと既存`nih_storage_read`へのadapterの2 objectで成功|

RV32のcaller-owned workspaceは4,144 B、hostでは4,152 B。
nativeの実DMA先は既存の固定SRAM stagingのままで、このworkspaceをDMA先へ追加していない。
workspace/contextのpinと、callbackがDMA停止・descriptor返却・cache返却後にだけreturnすることは、
呼出し側の契約である。host mockはそのhardware fenceの証明ではない。
既存native exportは未成立のfenceをfatal quarantineにするが、この試験でsiliconへ失敗を注入していない。

単調増加epochとsticky faultはdisk sessionの条件であり、cached `FIL`やVFS public handleの検査ではない。
outer Backendがmountを失効させ、FS objectを破棄してから再bindする必要がある。
PR #3のchain / ancestry / identity shimとpartition validationはまだこの接続へ組み込んでいない。
valid fixtureでのraw FatFs試験を、破損媒体のnative mount許可には使わない。
`FATFS`、open file、LFN stack、shim、upstream codeを含む最終imageの配置・メモリ予算も未検証である。

Zig Debug / ReleaseSafe各200件、Python 184件、format / ZLint / ShellCheck、既存6 native ELF監査も成功した。
これらのZig試験はcode変更がないためcache結果を再利用した。
host VFS PR #3や他セッションのbranchは変更せず、fixture生成codeだけ固定版から再利用した。
[再利用元と契約](../../probes/fatfs-disk/README.md)と
[計画上の残gate](../planning/storage-io-lifetimes.md)も参照。
