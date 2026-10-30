# FatFs read-only packageのLinux検証と引渡し

2026年10月27日。[macOSの記録](2026-10-27-fatfs-readonly-host.md)に続き、
Ubuntu 24.04の隔離containerで同じpackageを検証した。
レビューbranchは公開main `b7658d6`を土台に、VFS coreとFatFs packageの2 commitだけをcherry-pickした。
元branchの別系統のnative・allocator・書籍変更は取り込んでいない。

## 検証対象と環境

- source: `bfbeec4824b4a77853293b09ab10f611ab51b9f6`。git archiveで取得したcommitそのもの。
- Ubuntu 24.04.5、Linux arm64、Clang 18.1.3、Python 3.12.3、ASan＋UBSan。
- 独立checker: dosfstools 4.2の`fsck.fat -n`、exfatprogs 1.2.2の`fsck.exfat -n`。
- base image: `ubuntu@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55`。
- 実行: `CC=clang python3 tools/run-fatfs-host.py --require-oracles`。

[全139 caseの結果](evidence/2026-10-27-fatfs-linux-host.json)と
[環境・package version・report hash](evidence/2026-10-27-fatfs-linux-environment.json)を保存した。
containerへはcommitのsourceをコピーし、host作業ツリーや実deviceをmountしていない。
repositoryの別作業ツリー、SD、Flash、native firmwareへ書き込んでいない。

## 結果

**139/139 PASS**。macOSの138件との差は、独立checkerによるexFAT検査が1件加わったことである。

| 検査 | 結果 |
| --- | --- |
| 5種類のimageとfault/negative control | 全て期待した結果 |
| FAT12/16/32 | 独立した`fsck.fat -n`が成功 |
| exFAT | 独立した`fsck.exfat -n`がcleanと判定。2 directory、12 file |
| 読取り専用 | 通常readerのwrite呼出し0、明示的なwrite試験は拒否、前後のimage hash一致 |
| sanitizer | readerとfixture writerがASan/UBSan付きで完了 |
| macOSとの比較 | 5 imageとも、logical bytes全体のSHA-256がmacOSで生成したものと一致 |

レビューbranchのhost回帰もDebug/ReleaseSafe各170件、Python 90件、fmt、ZLint、
既存6 profileのnative ELF link/auditが成功した。VFSはnative imageへ接続していない。
元branchの121件という記録を170件へ書き換えず、対象revisionごとの証拠として分離する。
新しいPRのLinux amd64 remote CIとは別の、local Linux arm64結果である。

## 引渡し時の判定

このpackageはVFS契約とread-only imageのhost回帰を提供する。
FSの読取り、媒体の構造整合性、application dataの完全性、保存の耐久性は別々に判定する。

FAT chainの自己循環は、このLinux実行でもraw FatFsが同じclusterを繰り返して読めるnegative controlとして残った。
正常に返ったreadや、今回の正常fixtureに対するfsckの成功を、壊れた媒体一般の安全性へ拡張しない。
read-call budgetとsubprocess timeoutはhost試験を終息させる仕組みであり、native driverの取消実装ではない。

native側の受入条件は次の通りとする。

1. 循環・範囲外chain・directory循環を検出または有界に停止させ、`Corrupt`等の明示的な失敗へ変換する。
   そのpolicy、探索量の上限、取消、状態の回収を先に定める。本coreのerror/APIを必要に応じて拡張する。
2. packのhash検証は内容確認として使い、chainやpointerの構造検査の代わりにしない。
   検査結果をcacheする場合はmount世代、file identity、版と結び、抜去・外部更新で失効させる。
3. 空fileのcluster 0、LFN/8.3別名、case違いを扱うstable identityを確立し、root/FDの権限を接続する。
4. mount/client/objectのadmissionとbackend寿命を既存storage owner/RPCへ接続し、DMAの終息を確認する。
5. native実機で読取り・破損・抜去・取消を評価した後に、対応範囲を公開する。
   FAT/exFAT書込み、SQLite永続更新、電断回復は引き続き別の受入gateとする。

既存storage ownerや共通ログの実装担当は、このhost fixture/packageを取り込み、実backendとの境界で再実行できる。
本branchからnative serviceやon-media formatの置換は行わない。
