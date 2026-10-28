# 実exFATカードの読取りと終了処理

2026-10-28。candidate source `c18c1ca`。Tab5 / ESP32-P4 rev1.3で、挿入済みの別カードを
1回のwarm USB reset起動から読取り専用でprobe・mount・readした。
[構造化結果](2026-10-28-fatfs-card-physical.json)と
[生ログ・監査・復元記録](evidence/2026-10-28-fatfs-card/)を保存した。

|確認|実機結果|
|---|---|
|device|247,808,000 sectors、各512 B|
|volume|exFAT、MBR第1partition、開始LBA32,768、長さ247,775,232 sectors|
|選択fileのread|140 Bを2回、CRCは両方`0x53974ff0`|
|FatFs disk read|9 sector（volume probeのreadとは別）|
|終了|private FS destroy、disk detach、generation 3のsession終了が成立|
|broker|32,768 Bを課金・pin、終了後clear/unpin/freeとaccount回収|
|boot stack|観測3,200 B、guardを保持|

fileの選択はroot直下の最初の非empty・1 MiB以下の通常fileで、最大64 entryを調べる。
今回は140 Bが読めた。file名はCRCのみ、内容はbyte数とCRCのみを記録し、内容そのものは保存しない。
CRC一致は同一prefixを2回読んだ自己整合性で、外部の既知content oracleとの一致ではない。

既存のraw SD 3 transport・分散read、broker停止後のDMA completionとI/O寿命試験、
組込みFAT12上のnative FSD/client取消・kernel停止・rebind・回収も同じbootで通過した。
SQLiteは既存のmemory-only workloadである。挿入済みカード用profileではlittlefs boot probeを実行せず、
littlefsの資格・storage recordも結果へ含めない。
native VFS/RPCを実カードへ接続した試験や、mount後の実カード抜去・取消の資格には数えない。

## 候補と採取

candidateは850,016 B。ELF/image、loader、source mapを固定し、Flash上のloader/partition/appを
採取前後に照合した。同じexclusive serial FDを保持し、kernel排他とcu/tty両aliasのraw opener拒否を確認した。
PASS後10秒の監視と、生ログ全体のchecker通過を含めて合格とした。
source profileにはboot modeを含め、immutable ELF descriptorと異なるmodeへmetadataだけを変更した実ELF監査は拒否した。
Python235件、[hostの5形式のread/teardown試験](2026-10-28-fatfs-card-host.md)も通過している。

最初の採取開始は別PIDのserial使用によりFlash command前に拒否した。
次の試行は旧littlefsカードで既存試験を終え、カード交換待ちの300秒がoperator確認の直前に終了した。
その試行から実カードの成功を主張せず、失敗ログと全面復元記録を保持した。
交換後は再交換を求めず、挿入済みFAT/exFATカード専用の明示profileで新たに採取した。

## 復元と未確認範囲

元Flash16 MiBをprivateに退避し、候補が触れたerase-aligned範囲を復元後、
Flash全体のdigest一致を確認した。serialは解放済み。別カードが残っている間は元firmwareへのresetを保留し、
ROM download状態を維持する。backup本体はrepositoryへ入れない。

2回の試行直前backupのapp領域には相違があり、原因は確定していない。
各試行はそれぞれの直前snapshotへ戻しており、最後の復元基準はJSONに記載した最後のbackupである。
試行間の同一firmwareを仮定しない。候補自体の前後照合と同一FDによる採取は最後の試行内で成立している。

観測stackは今回通過した経路のpaint値で、総call stack・最大IRQ負荷の上限ではない。
確認した実カードは今回のexFAT入力1枚である。native FAT12/16/32、native VFS/RPC over SD、
clean POR、書込み、SQLite永続化と電断復旧は別のgateとして残る。
