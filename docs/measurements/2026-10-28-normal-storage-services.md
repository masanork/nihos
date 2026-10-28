# 通常OSのread-only FSとC6共有ホスト

通常の画面・入力・C6サービスを止めずにSD VFSを使う実装を追加した。
既定のdevice integer buildで有効にし、`NIHOS_NATIVE_NORMAL_STORAGE=0`で無効にできる。
検証用のSDMMC/broker profileは別のままで、通常起動ではheapの退役・破壊試験を行わない。
責任境界と操作は[契約](../planning/normal-storage-services.md)に記した。

|検証|結果と範囲|
|---|---|
|通常FSのhost実行|5形式×9ケース＝45。実際のC/FatFs→VFS/RPC→SD driverをmodeled MMIOへ接続|
|形式|FAT12、FAT16、FAT32、MBR FAT32、exFAT。全imageの前後hash一致|
|異常系|カードなし、世代失効、I/O失敗と再mount、抜去と再mount、破損volume、OOM、空root、cache fence失敗|
|欠陥注入|旧世代submitの許可、cache handoff失敗の無視を入れると同じ実行試験が失敗|
|native link/image|connectedとnetworkなし。既存6 SDK-free構成と独立C6 fixtureもlink/audit成功|
|改変sidecar|source/object hash、parent容量、function追加、manifest欠落の5種を実ELFに対し拒否|
|既存回帰|Zig Debug/ReleaseSafe各509件、Python 402件、既存guarded VFS/RPC suite、static analysis|

この表の実行証拠は`cb774ad`時点。後続のmain graphics追加は別の回帰検証として扱う。
[host JSON](evidence/2026-10-28-normal-storage/host.json)にsource/upstream/object hashと全ケースを残した。
[image audit](evidence/2026-10-28-normal-storage/image-audit.json)は専用RX textとread-only data、
64 KiB parent、既存4 KiB worker、禁止write/heap APIを確認している。
[sidecar否定試験](evidence/2026-10-28-normal-storage/normal-fs-negative-controls.json)も保存した。

最大の個別frameは1248 B。disk callbackを候補calleeとして加えた
[構造的chain](evidence/2026-10-28-normal-storage/normal-fs-stack.json)は3168 Bだが、
ROM cache・syscall・callbackなど8関数に未解決境界がある。全call stackの上限を証明した値ではない。

実機の最終候補はimage SHA-256
`5f59fd32e2da18ae138e9c4752b89dd463596f7512714e7251e8c55cd5a7b422`。
同じ排他シリアルdescriptorを保持し、候補を前後照合してwarm USB RTS resetで実行した。
現在のカードでCMD17のsector読取りを2回完了し、初回と`:storage`再試行のvolume admissionは
ともに`NIH_VOLUME_NOT_FOUND`（report error `-262`）だった。認識可能なFAT/exFAT volumeを
発見できないという結果であり、正常mount/file readの合格ではない。

その間UI frameは32→933、C6はRX 1201/TX 195、poll 1683まで進み、legacyの`:devices`も
受理された。Wi-Fi設定なしのC6 transport実行で、DHCP/IP疎通や物理タッチ操作の証拠ではない。
[実機結果](evidence/2026-10-28-normal-storage/physical-rejection.json)と
[抜粋](evidence/2026-10-28-normal-storage/physical-rejection.log)を残した。
先行2候補のmount/read受入未達もfailure JSONとして保存した。

Flash全体16 MiBを事前退避し、試験後は書き換えた範囲を復元して全体を照合した。
カード交換・format・SD writeは行っていない。元のfirmwareへwarm resetして排他を解放した。
各実機主張は上記の正確な候補に限定し、後続のsource/manifest変更へ自動で持ち越さない。

対応形式カードでの通常FS mount/実ファイルread、no-card実機起動、mounted removal/reinsertion、
in-flight abort、clean POR、全stack上限は残る。card-detect IRQ登録とnative post-CMD17 abort fixtureは
未実装。書込み・永続SQLite/WAL・電断復旧の証拠は追加していない。
