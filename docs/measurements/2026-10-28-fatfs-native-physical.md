# native FatFs FSD/clientの実機確認

2026-10-28。runtime修正 `4e193f6`、採取・検証source `087524a`。
ESP32-P4 rev1.3のTab5で、immutable FAT12 fixtureを使うnative FSD/clientを3回USB reset起動し、全回合格した。
[構造化結果](2026-10-28-fatfs-native-physical.json)と
[生ログ・検証記録](evidence/2026-10-28-fatfs-native/)へ、候補identityと結果を保存した。

入力はFlash内のsparse/RLE FAT12 imageであり、SD上のFatFsではない。
SDは既存のread-only littlefs fixtureを使い、formatやカードへの書込みは行っていない。
SQLiteは既存のmemory-only workloadで、永続DBではない。

## 実機で見つかった不具合

初回はbrokerとSD I/O寿命試験が通った後、FSDで`task invariant`になった。
段階番号と呼出元アドレスを加えた診断版では、mountと準備完了を通過し、
`runClient`の本人確認で停止した。clientが旧C allocatorの`nih_task_identity`を使っていた。
そのAPIはbroker移行時に引退して0を返し、符号化もCPUを含む別namespaceである。

FSDはkernelの`CURRENT`から取得した世代付きhandleを使い、registrationとexit通知のnamespaceに揃えた。
handleはこのCPU1 endpoint内で照合するもので、全CPU共通のprincipalを定義した変更ではない。
取消通知、submit、再生成後の本人確認にも同じ取得経路を使う。

修正版の実機は最後のPASSまで到達したが、旧ログ検証器はSQLite Flash上限を`0x400c0000`として拒否した。
image auditで認めているFatFs profileの`0x400d0000`を、完全なsource/fixture情報と
physical device profileがある場合だけログ検証でも認める。通常buildの上限は維持する。
保存済み実ログの全体replayと、上限/profile破損のhost負例を確認してから採取をやり直した。

失敗を成功runへ混ぜず、初回失敗、診断失敗、旧検証器の拒否、各Flash復元記録を別に保持した。

## 候補と試験経路

appは853,792 B、SHA-256 `293998316c43bbcb6b31a0eedf5a745212fa18cdc1a50e3ac906775d373a1eb2`。
ELF SHA-256は`ef04fcaed7cc2abcbc84b2d50ef2342e7227dc76f7e879f7cec3922fb253f385`。
fixture全体は1 MiB、SHA-256 `297d30b5b9794860f808b88fbf907239015d38cea680af6b5a9d1f45c3817e1d`。
採取ツールの修正前後でapp/ELFは同一である。
試験後は元のFlash16 MiB全面のdigest一致を確認して復元し、serialを解放した。

serialはadvisory lockとkernelの排他を取得し、cu/tty両aliasの第二openerがEBUSYになることを確認する。
同じFDでchip/MAC、16 MiB backup、partition、候補書込みとFlash上のdigestを確認してから実行する。
各USB reset起動のPASS後には10秒監視し、候補の事後照合を経て、元のFlashを全面digest一致まで復元する。
backup本体はprivate directoryのmode 600で保持し、repositoryには含めない。

|確認対象|全3回の結果|
|---|---|
|read中の取消|取消応答、length 0、reply buffer全体0|
|read中のclient停止|kernelが実taskを停止し、ownerが戻るまで親領域を保持|
|停止後のdrain|request 1件とreply 1件を破棄|
|再生成client|新しいkernel世代へrebindして24 Bを読取り、CRC `0x539c1754`|
|旧世代|handle / epoch / reply / exit通知を各1件拒否|
|RPC|request 8件、reply 6件|
|service parent|使用38,656 B、課金65,536 B、全clear後にpin解除・free|
|broker回収|service/client account終了後、internal/external両poolが全回復|

## stackと証拠の範囲

workerは4,096 B。guard16 Bとtask側trap context128 Bを除く通常SP予算は3,952 B。
全3回でowner 2,704 B、replacement client 352 Bを観測した。
これは試験した処理のpaint/guard観測値で、全call pathや最大IRQ負荷のstack上限ではない。
強制終了した最初のclientの最大値を、このreplacement値から推定してはならない。

この候補の静的call-chain解析は既知frameの構造上の合算が入口3,088 B、owner3,072 B、client288 Bで、
未提供frameは0。診断用ROM出力を含むcallback / ecall / ROM境界が未解決なので、総stack合格は出さない。
記録の`whole_call_stack_qualified`はfalseのままとする。

host Zig Debug / ReleaseSafe、Python232件、format / ZLint、最終image監査を確認した。
実ログの取消・世代・回収・stack・Flash spanを壊した8例は全て拒否した。
実カードへのFatFs接続、exFAT/VFATのnative実行、clean POR、書込み、永続SQLite、電断復旧は残るgateである。
