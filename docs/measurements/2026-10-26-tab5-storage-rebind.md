# Tab5: storage endpointの世代切替とreplacement client

2026-10-26。実行ソース `6c99109`、ブランチ `codex/tab5-psram-physical-fix`。
[未完了RPCを伴う強制終了](2026-10-26-tab5-storage-cancellation.md)に続き、
**停止したCPU1 clientを回収し、同じslot/stackを新しいtask generationで再利用する経路**を追加した。
設計は[ADR 0046](../adr/0046-storage-endpoint-epochs-and-rebind.md)。

## 実装

- Request/Responseに32-bit epochを加えた。ownerは古いepochの要求をsequence更新・backend操作の前に拒否する。
  clientはresponseのepochを確認し、同じsequenceを持つ古い応答を受け入れない。
- `Owner.rebind`は旧client停止後のrelease成功とqueue drainを条件に、新しいkernel由来identityへ接続する。
  生きたendpoint、zero/same client、残存queue、release失敗、epoch最大値を拒否する。
  新epochでsequenceは1から再開する。zero/wrapは許さない。
- CPU1 bootstrapが最初のclientをexit -98でterminateし、allocation cleanupとstorage ack後にreapする。
  同じslot 1・4 KiB stackをgeneration 4で再利用する。owner taskとhealthyなSD controller/mountは維持する。
  clientの再登録はresident flagsだけを初期化し、ownerは新identityを待ってepoch 2へrebindする。
- file tokenの単調増加counterを同じFS workspace内で維持し、旧handleを新openへ再利用しない。
  owner/controller再起動やFS workspaceのdestroy/initを伴う再接続ではない。
- 新clientは古いkernel handleでのexit通知、古いepoch要求・応答、旧file handleを試した後、
  同じファイルを全読取りし、open handleを残して通常EXITする。
  ownerが二度目のrelease、FS destroy/消去を行い、両taskのreap後にIPC領域を消去する。
- service manifest version 3の判定器は追加のtask generation、epoch拒否、再読取り、CPU1台帳を要求する。
  過去のversion 1/2画像・ログは従来条件で検証できる。

ここでepochは寿命の区別であり権限の証明ではない。trusted machine-mode taskの共有address spaceを使う。
owner identityをclient要求から受け取らず、kernelが登録した接続先に固定する前提は変わらない。
一般アプリ向けsyscallや権限/path分離は追加していない。

## 実機fixture

ESP32-P4 rev1.3、Flash 16 MiB、PSRAM 32 MiB、`/dev/cu.usbmodem101`。
同じexclusive serial descriptorを保持して、SDK referenceの新規実行、既知loader/native app書込み、
開始前verify、3回のUSB RTS起動、終了後verifyまで完了した。
ユーザーの指示に従いdevice backupは新規作成せず、loader/appだけを上書きしpartition tableを保持する。
SD sectorへのwrite/eraseは行わない。

従来のroot listing/stat/全読取り・拒否試験の後、clientを未完了RPCが残る状態で強制終了する。
同期read/DMA完了後・response publish前のbarrierを使い、未実行request 2件・未受信response 2件を破棄する。
これは転送中のDMA abortや任意命令位置でのkillの検証ではない。

再接続時、ownerがepoch 1・sequence 1の合成replyを意図的にqueueへ入れる。
replacementの最初の要求もsequence 1なので、sequenceだけでは誤受理する条件を作る。
**古いreplyの注入は合成fixtureであり、実際の遅延replyを観測したものではない。**
新clientが古いepoch要求を送ってもsequenceは進まず、その後epoch 2・sequence 1の要求を処理できることも確認する。

| 判定 | 全3起動の結果 |
| --- | --- |
| 最初のclient identity | `01010003` |
| replacement identity | `01010004`（同じCPU/slot、generation +1） |
| 再接続/古いepoch要求/古いepoch応答/古い終了通知の拒否/通常EXIT後回収 | 各1 |
| 旧file handle拒否 | 2（新open前、別tokenでの新open後） |
| 旧・新clientの全読取り | 各10,752 B、CRC32 `883551bf` |
| backendへ渡したoperation / client受信response | 62 / 63 |
| 拒否 | 8（従来5 + 旧epoch 1 + 旧handle 2） |
| 未実行request/未受信response破棄 | 2 / 2 |
| FS 8 KiB / IPC 8 KiB消去 | 両方1 |
| CPU0 ledger | opened 8、closed/completed 7、reuses/stale 4、owned/pending 0、forced 1 |
| CPU1 ledger | opened 9、closed/completed 8、reuses/stale 5、owned/pending 0、forced 2 |

client受信数には、epoch不一致で捨てた合成reply 1件を含めない。
実要求は新旧合計67件をqueueへ送り、うち不正size/opcode 2件と旧epoch 1件をbackend前で拒否、
62 operationをbackendへ渡し、残り2件は未実行で破棄する。
実要求から生成したresponse 65件のうち63件をclientが受け取り2件を破棄し、別に合成reply 1件を注入・拒否する。
これらはSD sector read数ではない。

従来のSD 1bit 400 kHz→4bit 400 kHz→4bit 20 MHz、分散1,024地点/段階、
300ラウンドSMP/PSRAM/heap、64往復IPI、後続SQLite 2セッション26文も合格した。
bootの容量・固定LBA・分散digest・FS/APIを今回のSDK referenceと比較し、runtimeの両CRCをboot結果と照合する。
SDKは同じlittlefs/backendと独立したSDK block IOを使うため、異なるFS parserとの比較ではない。

## ホストとビルド

Zig Debug / ReleaseSafe各166件、Python判定器117件が合格。
新しいhost試験は再接続の各拒否条件、旧epochがsequence/backendへ影響しないこと、
古いresponseの照合拒否、release失敗後の再接続禁止、epoch枯渇を扱う。
formatting/ZLint/ShellCheck、RV32 architecture contractと6 native ELFリンク監査も合格。
C filesystem/backendは変更していない。SD/新RPC経路をESP-EMUで実行したものではない。
remote CI、mainへの反映、pushは行っていない。

最初のビルドは31 fieldの固定record生成でZigのcomptime分岐上限1,000を超え、画像生成前に停止した。
`record.schema`のcompile-time quotaを10,000へ増やした。runtimeのformat/loopやallocationは変えていない。
失敗したbuild logを保存し、修正後の画像だけを実機へ書き込んだ。

## 範囲と続き

今回の再接続は同じowner/mountの寿命内の一対一切替である。
次は複数同時clientと同じCPUの任意workerとのpreemption、それに備える内部SRAM配置の整理。
owner/controller自体の再起動、FS破棄後のtoken管理、電源をまたぐepoch、一般アプリ向けkill/syscall、
C6 Wi-Fi/slot 1仲裁、hot removal、FAT/exFAT、SD書込み、永続SQL VFS、電源断回復は未対応・未資格確認。
TG0 periodic alarmは従来IPI phaseからdisarmのままであり、任意workerとの同時実行を保証しない。
今回もUSB RTS resetでありcold boot、PSRAM全ワード検査、SQL 1,000バッチは対象外。

## 固定画像と実機結果

全3起動で上表の判定に合格し、PASS後10秒以上の監視で追加trap/fail・再起動がなかった。
各起動のSDK比較も合格。最後のloader/partition table/app照合まで同じexclusive descriptorを保持した。

| 起動 | 採取秒数 | PASS後監視秒数 | owner区間のTG1 counter差 | 同区間のCPU1 bootstrap poll |
| --- | --- | --- | --- | --- |
| 1 | 37.331 | 10.015 | 141,245 | 5,334 |
| 2 | 37.320 | 10.004 | 141,124 | 5,335 |
| 3 | 37.316 | 10.002 | 141,097 | 5,330 |

TG1は1 MHz設定とreadbackを確認したが、外部計測器で周波数は検証していない。
区間にはmount・RPC・旧新clientでの全読取り・強制終了・再接続・回収を含み、帯域測定ではない。
全3起動でowner stackは3,216 B、client二世代の最大は1,920 B、boot FSは6,448 B、後続SQLiteは6,248 B。
4 KiB task stackからguard 16 Bとtrap 160 Bを除く残りはowner 704 B、client 2,000 Bだった。
paintによる固定fixtureの観測値であり、一般pathの最大stack保証ではない。

最終appは768,864 B、内部heapは49,664 B。前段49,792 Bから128 B減り、
48 KiB linker最低値に対する余裕は512 B。SQLite後のheap空きは16,022,848 Bへ回復した。

- app SHA-256: `9912763cd71d17892241ab5439311d3dd8090cbfb86d2a1f2dfa1064249d6666`
- ELF SHA-256: `8cc9a6d0503878c61cf6714d458df87f06d72a6572f8470eb6996cffcfbb90d6`

[画像・全ログ・SDK比較・audit・source patch・license・SHA256 manifest](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-storage-rebind-qualification)。
終了時点でこの最終画像を書込み・照合した。ポート解放後の他セッションによる変更は追跡していない。
mainの並行作業は変更していない。
