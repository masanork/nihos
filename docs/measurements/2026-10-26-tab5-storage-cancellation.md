# Tab5: 未完了storage RPCを残したclient強制終了

2026-10-26。実行ソース `d3f0dd9`、ブランチ `codex/tab5-psram-physical-fix`。
[通常EXITまでの前段](2026-10-26-tab5-storage-owner-rpc.md)に続き、
**未完了のRPCを残してCPU1 client taskを強制終了し、CPU0 owner taskで回収する経路**を追加した。
[ADR 0045](../adr/0045-storage-client-cancellation.md)を参照。

## 実装と試験の境界

- schedulerがclientをexitedにしてから、通常EXITと同じresident tombstoneを公開する。
  強制終了の判定はCPU1 bootstrapがMIEを止めた区間で行う。FS操作はowner taskだけで行う。
- ownerは同期readを完了し、endpointを閉じてopen handleをreleaseする。
  `clientExited(queues)`は未実行requestと未受信responseを捨て、件数を保持する。
  以後のdispatchは拒否し、二度目の終了処理はreleaseを繰り返さない。
- response consumer cursorの引継ぎはclient停止確認後だけ。queueにclientのbuffer pointerはない。
  両taskのreapまで待ってIPC 8 KiBを消去し、FS 8 KiBはowner destroy直後に消去を検証する。
- service manifestをversion 2にし、強制終了・処理中read完了・破棄件数とCPU1のforced台帳を
  log checkerの必須条件にした。version 1の過去ログは従来の条件で検証できる。

fixtureは従来と同じroot一覧、stat、10,752 B全読取り、CRC、EOF、不正size/opcode/handleの拒否を行う。
再openしたhandleを残したまま、追加readを2件送る。最初のreplyを未受信で残し、次の512 B readを
**同期block read完了後・RPC response publish前**のbarrierで止める。
clientはbarrier確認後に後続requestを2件積み、event待ちになる。
bootstrapがexit code -98でclientをterminateする。ownerがbarrierを抜けてreadのreplyを公開し、
request 2件・reply 2件を破棄する。

これはRPC処理の途中でのclient終了を確認する固定試験である。転送中のDMA abort、任意命令位置でのkill、
I/O timeout、hot removalを試験したものではない。SDへ書込みは行わない。

## 実機結果

ESP32-P4 rev1.3、Flash 16 MiB、PSRAM 32 MiB、`/dev/cu.usbmodem101`。
先行する画面検証プロセスの使用中は待ち、プロセスを強制終了していない。
ポート解放後、同じexclusive serial descriptorを維持してfreshなSDK reference実行、
既知loader/native appの書込み、開始前verify、3回のUSB RTS起動、終了後verifyまで完了した。
ユーザーの指示に従い新たなdevice backupは作らず、loader/appだけを上書きしpartition tableを保持する。

| 判定 | 全3起動の結果 |
| --- | --- |
| clientが受け取ったresponse | 38 |
| backendへ渡したoperation | 38（通常分36 + 追加read 2） |
| 不正要求/handleの拒否 | 5 |
| full request queueの非受理確認 | 1 |
| ファイル全読取り | 10,752 B、CRC32 `883551bf` |
| 強制終了/処理中read完了/owner release/終了後拒否 | 各1 |
| 未実行request/未受信responseの破棄 | 2 / 2 |
| FS/IPC予約領域消去 | 両方1 |
| 各CPU ledger | opened 8、closed/completed 7、reuses/stale 4、owned/pending 0 |
| forced台帳 | CPU0 1、CPU1 2（今回の強制終了でCPU1だけ +1） |

送信済みrequestは42件。うち不正size/opcode 2件はbackend前で拒否し、38 operationをbackendへ渡し、
残り2件は未実行のまま破棄する。生成response 40件のうち38件をclientが受け取り、2件をownerが破棄する。
`requests`と`responses`のログ値だけを総送信数やSD sector read数と解釈しない。

全起動で通常の300ラウンドSMP/PSRAM/heap、64往復IPI、後続SQLite 2セッション26文も合格した。
root 4項目、固定LBAと分散1,024地点のdigest、boot FS/API結果を今回のSDK実行とも比較し一致した。
runtimeのfile CRCはboot結果と照合する。SDKは同じlittlefs/backendを独立したblock IOで使うため、
別実装filesystem parserとの比較ではない。

## 失敗と修正

初版 `7794ead` はstorage task timeoutで不合格だった。
終了対象の条件が`.blocked`だけだったが、`waitEvents`の停止状態は`.waiting`である。
このためbootstrapがclientをterminateせず、ownerはtombstoneを待ち続けた。
`.waiting`を対象に修正し、event待ちからのterminate、通知拒否、generation変更後のstale handle拒否を
host試験に追加した。初版の画像・audit・source patch・raw log・capture errorを別保存した。
初版の失敗を最終画像の成功へ数えない。

ホストはZig Debug / ReleaseSafe各164件、Python判定器116件が合格。
formatting/ZLint/ShellCheck、RV32 architecture contractと6 native ELFリンク監査も合格。
今回C filesystem/backendは変更していない。今回のSD/RPC経路はESP-EMUで実行していない。
remote CI、mainへの反映、pushは行っていない。

## 続き

一対一のtrusted native qualificationは通常EXITと今回の固定強制終了まで。
次はendpoint再作成とgenerationをまたぐ古い要求の拒否、複数client、同じCPUの任意workerとのpreemption。
一般アプリ向けkill/syscall ABI、path権限分離、C6 Wi-Fi/slot 1仲裁、hot removal、FAT/exFAT、
SD書込み、永続SQL VFS、電源断回復は未実装・未資格確認。
TG0 periodic alarmは従来IPI phaseからdisarmのままで、任意workerとの同時実行を保証しない。
今回もUSB RTS resetであり、電源OFF→ONのcold bootやPSRAM全ワード検査、SQL 1,000バッチは対象外。

## 固定画像と測定値

全3起動で上表の判定に合格し、PASS後も10秒以上監視して追加trap/fail・再起動がなかった。
各起動のSDK比較も合格。最後のloader/partition table/app照合まで同じexclusive descriptorを保持した。

| 起動 | 採取秒数 | PASS後監視秒数 | owner区間のTG1 counter差 | 同区間のCPU1 bootstrap poll |
| --- | --- | --- | --- | --- |
| 1 | 37.319 | 10.036 | 108,659 | 4,301 |
| 2 | 37.286 | 10.003 | 108,924 | 4,314 |
| 3 | 37.480 | 10.199 | 108,640 | 4,302 |

TG1は1 MHz設定とreadbackを確認したが、外部計測器で周波数を検証していない。
区間にはmount・RPC・全ファイル読取り・取消し・回収を含み、帯域測定ではない。
全3回でowner stackは3,200 B、clientは1,360 B、boot FSは6,368 B、後続SQLiteは6,168 Bだった。
4 KiB task stackのguard 16 Bとtrap 160 Bを除く残りはowner 720 B、client 2,560 B。
paintによる固定fixtureの観測値で、一般pathの最大stack保証ではない。

最終appは766,304 B、内部heapは49,792 B。前段50,176 Bから384 B減り、
48 KiB linker最低値に対する余裕は640 B。後続SQLiteのheap空きは16,022,848 Bへ回復した。

- app SHA-256: `99273d20951367bd76e064f4cb1ee62fd884ab87ecca7230df0e281450c8eb5b`
- ELF SHA-256: `cc2d8fdc1ee21770311345e52ec277d4d4f4d33976d5721feca9d367aea8efc9`

[画像・全ログ・初版失敗・比較・audit・source patch・license・SHA256 manifest](/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-storage-cancellation-qualification)。
終了時点でこの最終画像を書込み・照合した。ポート解放後の他セッションによる変更は追跡していない。
mainの並行作業は変更していない。

続報: [endpoint世代切替とreplacement client](2026-10-26-tab5-storage-rebind.md)。
