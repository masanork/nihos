# native SDMMCの取消・抜去通知とlease返却の実機確認

2026-10-27。実装commit `ad627039ec997a2442a58e464511e5d4e769d6ac`。
[host / candidate検証](2026-10-27-native-storage-io-host.json)の固定imageをTab5で3回USB reset起動し、全回合格した。
試験後は実行前のFlashへ復元し、16 MiB全体のdigest一致を確認した。serialは解放済み。

対象はESP32-P4 rev1.3、MAC `e8:f6:0a:e2:e8:9c`、PSRAM 32 MiB。
SDは30,867,456 sector、各sector 512 B。既存のread-only littlefs fixtureを使用し、カードのformatや書込みは行っていない。

appは821,104 B、SHA-256 `fb07319f021cce040300407222eedbc3813ae70957cb173115bff8cab5575258`。
ELF/source/loader/cache設定のidentityは[構造化結果](2026-10-27-native-storage-io-physical.json)と固定bundleに保存した。
この試験はFatFsの実カード接続やSQLiteの永続DBを検証したものではない。

## 確認した順序と全3回の結果

同じexclusive serial FDを保持したまま、対象chip確認、Flash全体の退避、partition照合、loader/appの書込み、
候補の事前Flash照合、3回のUSB reset起動と各PASS後10秒の監視、候補の事後照合を行った。
既存brokerがclient強制終了後の実SD readを完了した後、新しいI/O寿命試験へ進んだ。

|確認|全3回の結果|
|---|---|
|通知なしのread|通常transportと新しいcard sessionで各1回成功|
|LBA 0の内容|両方ともboot時のCRC `0x9022e83d`と一致|
|CMD17発行後の取消通知|成功結果として公開せず、destinationの`0xa5`を維持|
|CMD17発行後の抜去通知|成功結果として公開せず、destinationの`0xa5`を維持|
|停止とcache返却|両要求のfence成立後にだけleaseを回収|
|旧ticket拒否|完了後と新session開始後の計3件|
|抜去通知後のread|command数を増やさず拒否|
|controller / IDMAC|DMA enable、reset bit、bus mode、IDMAC FSMの最終値は0|
|IRQ / descriptor|両interrupt mask、descriptor base、descriptor wordの最終値は0|

取消後は元controllerをfaultedのまま再利用せず、停止確認後にSD電源とcontrollerを初期化し直して別sessionにした。
通知ticketは巻き戻さない。これはカードslotの再初期化であり、Tab5本体の電源OFF→ONではない。

既存のSMP 300 round、64 IPI、SDMMC 3 transportの各1,024箇所の分散readも全回合格した。
SDの合計readは3,096回、storageは10,752 Bのfileを2 pass読み、owner/client強制終了と再bindも成功した。
SQLiteのmemory-only workloadは2 session / 26 statementが成功。
観測stack使用量はSQLite 6,552 B、storage owner/client 3,328 / 1,920 B、broker client 448 Bだった。
これらは通過した経路の観測値で、新しいqualification関数を含む全経路や最大IRQ負荷の上限ではない。

## 元のFlashの復元

退避は16,777,216 B、backup fileはmode 600、出力directoryはmode 700で保持した。
loader `0x2000`とapp `0x10000`の候補が触れたerase-aligned範囲を元に戻し、partition tableは変更していない。
最後に`verify_flash 0 flash-before.bin`でFlash全体のdigest一致を確認し、通常のresetへ戻してFDを解放した。
退避時と復元照合時のSHA-256は`5d1a5e7d9f014ac79a5dab59353162d6fa9000529919fbeb3727f556b1683e23`。
インストール状態はこの試験終了時のsnapshotであり、他セッションの後続書込みを固定しない。

[固定候補・source・生ログ・全結果の保存先](/Users/masanork/Documents/Codex/2026-10-27/nihos-vfs-native-lifetimes-host-candidate)
の`physical-1`にはprivateなFlash backupもある。backup本体を公開artifactへ含めない。
26ファイルのSHA-256を保存・再照合し、生ログ3件を現行判定器でも再検証した。

## 残る範囲

通知は実CMD17 register write後にsoftwareから入れた。実際のカード抜去を観測した試験ではなく、
通知時点でsiliconのDMA転送がまだ継続していたという保証もない。
driverはpolling専用でSD IRQ handlerを登録しないため、非同期IRQ処理の全寿命を実証したとは扱わない。
停止/cacheの失敗注入での隔離はhost MMIO modelで確認済みだが、silicon上の失敗は未注入。

実カードの抜去・再挿入、本体の電源OFF→ON、FatFs BackendとVFS/RPCの接続は未実施である。
