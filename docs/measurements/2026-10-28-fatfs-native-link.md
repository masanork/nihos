# Native FatFs RPC fixtureのlinkと配置監査

2026-10-28。base `f02a167`。`NIHOS_NATIVE_FATFS_RPC=1`を明示した候補に、実FatFs、
VFS/RPC v2、生成済みdevelopment policyの実broker、既存native task schedulerをlinkした。
今回実行したのはhost試験とELF/image監査で、serial接続、Flash書込み、電源操作は行っていない。
[結果JSON](2026-10-28-fatfs-native-link.json)へ候補とsourceのhash、配置、回帰結果を保存した。

## 実装した試験経路

従来のSD/littlefs boot probeとbroker試験の後に、CPU0のFSDとCPU1のclientを起動する。
既存のstorage task種別、kernel identity、IPI、waitEvents、強制停止`-98`、reap後の再admitを使う。
旧littlefs RPC task試験とは選択式で、同時に同じABIを使用しない。通常構成の既定値は変更しない。

入力は1 MiBの**組込みFAT12 fixture**で、SD上のFatFsではない。
元のfixture writerを別実行ファイルとして使い、非zero 31 sectorを3,942 BのRLEと248 Bのindexに圧縮する。
実際のCデコーダで2,048 sector全てをhostで復元し、元imageのSHA-256一致、範囲外/null拒否、
同じproviderに接続したguarded FatFsで`Memo.txt`の24 B読取りを確認した。
upstreamは従来と同じhash固定のR0.16 + official p1/p2である。

native経路には次の判定を組み込んだが、実機ではまだ実行していない。

- 同期readの途中で実client taskから取消を通知し、FS return後の`-125`と応答全体のscrubを確認する。
- 次のreadの途中でclientをkernel側で停止し、後続requestとactive replyを破棄する。
- 停止したclient専用accountの8 KiBを回収しても、FSDの64 KiB pin/chargeを保持する。
- replacement clientへrebindし、旧epoch/file/reply/exit通知を拒否して新たな読取りを行う。
- RPC shutdown、private FS destroy、parent全体clear、unpin/freeを完了し、両taskのreap後にservice accountを閉じる。

read途中の待合せはCPU fixture callbackであり、DMAを走らせたまま止める実験ではない。
実SDの既存broker readとI/O lifetime試験は、このfixture phaseより前に独立して残す。

## 配置とstackで見つかった問題

broker試験終了後の予約済みIPC `0x48008000` / 32 KiBをcontrolとして再利用し、現Stateは360 B。
parentは別のbroker external poolから64 KiBを確保し、使用末尾38,656 B、client frameは4,696 B / charge8,192 B。
IRQ hookと通知wordは内部SRAMに置き、hookはPSRAMやFS、brokerを呼ばない。
ELF内のcontrol descriptor、通知のaddress/size、読取り専用のfixture全体hashも監査する。

既存worker stackは**4 KiB**である。従来記録の8 KiBは将来計画の値であり、現workerへの割当ではなかった。
初期候補の入口に4,320 Bのframeがあり、さらにメタデータを有効にするとVFS openAt7,008 B、
broker alloc5,872 Bが判明した。配列を値で反復する際の全体copyを参照へ変え、owner/clientの入口も分けた。
初期候補は不適合として結果JSONへ残し、実機には書き込んでいない。

Zigの最適化済みbitcodeを同じbundled LLVMでobjectへ再emitし、最終ELFにstatic frame metadataを残す。
実測frameでZig側1,024 B ceilingとguard wrapper128 B ceilingを監査し、旧大frameを拒否するnegative testも追加した。
C側はインライン展開を止め、LFN用の局所bufferをparents/identity/openで同時に積まないようにする。
最終候補の最大static frameは1,248 B、Zig側496 B、guard wrapper80 B。
これは全call graph、間接callback、例外経路を含めた4 KiB stack合格ではない。
実taskでstack paintとguardを観測するgateは残る。

SQL共用Flash spanはこのopt-in構成だけ640→704 KiBへ増やした。
SDK v5.4.4の64 KiB MMU page / IDROM window内であり、SRAMやbroker floorは拡張しない。
primary residentは106,176 B、cold-placement policy上限106,496 Bまで320 B。
旧構成が拡張後のFlash範囲を勝手に受け入れないことも試験した。

## 再実行

```sh
NIHOS_NATIVE_FATFS_RPC=1 NIHOS_NATIVE_COLD_FLASH=1 \
NIHOS_NATIVE_MEMORY_BROKER=1 NIHOS_NATIVE_HIGH_SRAM=1 \
NIHOS_NATIVE_SDMMC=1 NIHOS_NATIVE_SDMMC_PROFILE=2 \
NIHOS_NATIVE_STORAGE=1 NIHOS_NATIVE_STORAGE_SERVICE=1 \
sh tools/build-native-elf.sh device build/native-fatfs-fixture sqlite
python3 tools/check-fatfs-native-input.py build/native-fatfs-fixture/fatfs-fixture-manifest.json
python3 -m unittest discover -s tools -p '*test.py'
```

builderはfinal ELFの配置・fixture・frame監査まで実行する。
CIにも同じlink/host decoder試験を設定した。今回記録した成功はlocal実行である。
ログ判定器はこのimage設定の時だけ`NIHOS_NATIVE_FATFS_RPC`を要求し、欠落・重複・値違い・順序違いを拒否する。
成功ログを将来取得しても、入力sourceはembedded fixtureと明示し、実カードFatFsの合格にはしない。
実ELF/manifestのfixture・配置・source等を改変する13件の負例も監査が拒否した。

local回帰はhost FatFs/VFS/RPC69 scenario、Zig Debug / ReleaseSafe各238件、Python194件、
format / ZLint / ShellCheck、既存6 native ELF link、旧capture/broker/SQLite/littlefs候補のimage監査が成功した。
旧候補のresidentは106,304 Bで、同じpolicy上限まで192 Bだった。

残るgateは実taskの起動・停止・wakeupと総stack観測、実カードFatFsとcontroller fenceの接続、
clean power-on、複数FS routing、永続SQLite、書込み・電断耐性である。
