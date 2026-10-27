# FatFs / VFS / RPCとbroker親領域のhost統合

2026-10-28。base `1347f73`。RPC v2と64 KiBのservice-owned parentを追加し、
実FatFs・実VFS・生成済みdevelopment policyを使う実brokerへ接続した。
実行はhostの同期sector callbackで、nativeではcomponent compileとlayout確認までである。
serial接続・Flash書込み・電源操作は行っていない。

[結果JSON](2026-10-28-fatfs-rpc-host.json)に69 scenario、source/upstream/object hash、
imageの前後hash、RV32 layoutと既存native profileの回帰監査を保存した。
再実行は`python3 tools/check-fatfs-backend.py`。CIへ同じ試験を設定したが、記録した成功はlocal実行である。

## 確認した動作

FAT12 / FAT16 / FAT32 / MBR FAT32 / exFATのguard・identity・失効等58 scenarioに加え、
各formatでread中のcancelとclient exitを注入し、exFATではRPCの64-bit offsetで4 GiB超を読んだ。
全5 imageの全体SHA-256は前後一致し、C側ASan / UBSan、Zig側ReleaseSafeで成功した。

sector callback中にclientを停止済みとして通知し、その単一actor accountの別leaseを実brokerで回収した。
service parentは別の`.vfs` ownerに属し、早期freeはBusy、clientからのfreeはWrongOwnerになる。
dispatch中のretireもBusyとなり、serviceの64 KiB pinとchargeを保持したままFSが戻ることを確認した。
これは停止通知のhost注入であり、native schedulerによる実task killや転送中DMA抜去の測定ではない。

cancelは同期backendのfence済みreturnを待ち、応答をscrubして`-125`にする。
controllerを強制abortした、取消でmountが健全になった、という意味ではない。
client exitではactive結果、未実行request、未読replyを破棄し、FDをowner側で閉じる。
別clientへのrebind後に旧handle / epoch / notificationを拒否し、新たな読取りが成功した。
client account全体の回収は、そのaccountの全taskが停止していることを別途必要とする。

終了時はRPC shutdown→private FS destroy→parent全体clear→unpin→freeの順で全pageを回収した。
unitではprivate FS destroyがBusyの間、closing ownerのreaperもwaitingのままとなり、
成功後にだけ回収できることと、pin admission失敗時のallocation rollbackも確認した。

## RV32の配置

|64 KiB parent内|offset|bytes|
|---|---:|---:|
|disk|0|4,152|
|C Backend|4,224|15,712|
|RPC owner（VFSを含む）|19,968|8,680|
|request/reply queues|28,672|9,984|
|使用末尾|38,656| |
|broker charge| |65,536|

128 B境界で配置し、VFS単体3,520 BをRPC ownerへ二重計上しない。
bulk parent外にはnotification 28 Bとparent coordinator 72 Bを保持する。
client frameは4,696 B、別accountのchargeは8,192 B。
message ABIはrequest 560 B / response 4,136 Bで、pointer、自己申告principal、可変長messageを含まない。
pin、通知、queue、FDの寿命は[計画](../planning/storage-io-lifetimes.md)と
[試験契約](../../probes/fatfs-disk/README.md)に記す。

開発profileのVFS external枠524,288 Bとfloorを変更せず、このserviceと小さなclientをadmitした。
完全なVM、network、UI等を同時稼働させたpeakや、最終native code/global/stackの配置合格ではない。
RV32ではRPC step、exit/cancel atomics、実brokerによるParent reserve/retireもinstantiateしてcompileした。

Zig Debug / ReleaseSafe各238件、Python 184件、format / ZLint / ShellCheck、既存6 native ELF監査が成功した。
既存capture/broker/SQLite/littlefs profileも再buildしてimage監査に成功し、resident 106,176 B、
policy上限まで320 Bだった。これは新RPCをlinkしない既存profileの回帰結果であり、
新RPCを実機搭載できる余裕があるという証明ではない。

native task stop/wakeup、IRQ resident配置、controller abortとの結合、最終link・task stackの検証は残る。
clean power-onと実カードFatFs、永続SQLite、書込み・電断耐性は引き続き未確認である。
