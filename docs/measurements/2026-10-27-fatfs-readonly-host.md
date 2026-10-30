# FAT/VFAT/exFATのread-only host検証

2026年10月27日。`codex/vfs-host-contract`、base `5b295051ee56f95c6d2dd875aec95cd21ced7310`。
共通VFSのhost契約coreとは独立に渡せる、FatFs image検証一式を実装した。
別系統の共通ログ方式、既存native storage owner/RPC、実機firmwareには変更していない。

## 再実行と対象source

```sh
python3 tools/run-fatfs-host.py
# Linuxでdosfstools/exfatprogsを導入済みの場合
python3 tools/run-fatfs-host.py --require-oracles
```

[実行スクリプト](../../tools/run-fatfs-host.py)、
[bootstrap](../../tools/bootstrap-fatfs.py)、
[probeの構成と引渡し条件](../../probes/fatfs/README.md)、
[機械可読の全結果](evidence/2026-10-27-fatfs-readonly-host.json)を保存した。
後者にはcompiler、host、各source hash、fsck binary hash、image hash、全caseの観測値がある。
今回のhostはmacOS arm64、Python 3.9.6、Apple Clang 21.0.0。

FatFs R0.16の元archiveと公式patch 1・2をhash固定し、patch適用後の`ff.c`も確認する。
patch 2は2026年7月10日の公式修正で、破損FATサイズやexFAT cluster数等の検査を含む。
取得元・hash・licenseは[provenance](../../provenance.toml)に記録した。
upstream sourceはrepositoryに複製せず、bootstrapしたsourceの著作権・license headerを保持する。
公式根拠は[patch一覧](https://elm-chan.org/fsw/ff/patches.html)と
[設定仕様](https://elm-chan.org/fsw/ff/doc/config.html)。

## 確認した結果

| 対象 | 結果 |
| --- | --- |
| FAT12 / FAT16 / FAT32 superfloppy | mount、directory、内容、別名、日本語名の読取り成功 |
| MBR内の単一FAT32 partition | 同じ読取り成功。partitionを独立したblock viewへrebase |
| exFAT | 同じ読取り成功。short aliasがないことも区別 |
| VFAT LFN / UTF-8 | case違い、LFN/8.3別名、結合濁点、非BMP、255 UTF-16単位の長い名前を検査 |
| 断片化file | 各形式で7か所のcluster境界をまたぐ内容を照合 |
| 64-bit | 4 GiB＋8 KiBのexFAT fileで2 GiB/4 GiB境界をまたぐ16-byte markerと末尾EOFを照合 |
| 破損・範囲外 | boot signature、FATサイズ、cluster link、exFAT cluster数、partition/device境界、volume/partition境界を拒否 |
| 読取りbudget | 下位read拒否をmount成功にしないことを確認 |
| 書込み禁止 | 入口で拒否、read-only buildからwrite APIを除外、block write stubも拒否 |
| sanitizer | host readerとfixture writerをASan＋UBSanで実行し、全case成功 |
| 独立した実装での検査 | macOS `fsck_msdos -n`でFAT12/16/32の3 volumeが成功 |
| image不変性 | 5種類の全imageのSHA-256が実行前後で一致 |

**138 case PASS**。この数はnegative controlと3件の独立fsck検査を含む。
実行中の通常readerはdisk write呼出し0回。低層write拒否試験だけは明示的に1回試み、
`RES_WRPRT`を返した後もimage hashが変わらないことを確認した。
exFAT imageはlogical 6,442,450,944 bytes、今回のhost割当は6,668,288 bytes。
全imageのhashを取るための順次読出しは行うが、file内容をRAMへ全ロードしない。

既存host回帰はZig Debug/ReleaseSafe各121件、Pythonの既存52件、fmt、ZLint、diff checkが成功。
新しい[Linux向けworkflow](../../.github/workflows/fatfs-host.yml)は追加したが、remote CIは未実行。
Linuxでは独立した`fsck.fat`と`fsck.exfat`の両方を必須にして同じpackageを実行する。
今回のmacOS結果はLinux CIやexFATの独立相互運用試験の代用にはしない。

## 発見した契約の差とnegative control

1. upstreamのread-only buildは`FA_READ | FA_WRITE`のwrite bitを除去し、読取りopenとして成功する。
   nihos入口は書込み要求を明示的に拒否する必要があり、probeでもmount前に`ReadOnly`を返す。
2. upstreamは今回の署名欠落FAT12 VBRをmountする。probeの通常入口ではboot signatureを必須にし、
   MBRとvolumeの境界も事前検査する。rawなupstream入口の成功例も結果JSONへ残した。
3. FAT32 chainの先頭linkを自己循環へ変更すると、今回の有界readは先頭clusterの内容を繰り返して成功する。
   これは検出成功の証拠ではない。FatFs単体を壊れた媒体の完全な整合性検証器とみなせない実例であり、
   nativeで破損volume一般を扱うための未解決gateとして残す。

破損はread-only overlayで再現し、元imageを変更しない。
各subprocessはwall-clock deadline、disk readは回数上限、directory列挙は件数上限を持つ。
hostでの封じ込めは、nativeの最悪CPU時間・取消・DMA終息の証明ではない。

## 引渡しと残るgate

このpackageは既存OS VFSへFatFsを接続していない。native側ではまず以下を解決する。

- stable file identityとaliasの同一性。特に空fileの開始cluster 0を同一IDと扱わない。
- mount世代、owner寿命、FD/client/objectのadmissionと資源回収。
- 循環chain等への対応方針、部分I/Oとdevice抜去、I/O時間の上限。
- UTF-8 path 511 bytesの公開上限と、列挙できる765-byte LFNの違いを扱うUI/API。
- LFN stack workspace、Unicode table、cache、C ABIを含めた実機のメモリ・code size。
- 独立に作られたexFAT媒体との相互運用、SD driver、DMA、実機での反復検証。

fixture生成用write buildはprivate host imageを作る道具だけであり、
nihosでのFAT/exFAT書込みやSQLite永続更新、電源断回復を資格化しない。
VFS導入を共通ログ方式の完成待ちにせず、このpackageはbackend接続時の回帰fixtureとして使う。
