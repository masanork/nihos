# 実カードへ接続する前のvolume admission

2026-10-28。実装は[fatfs_volume.c](../../src/storage/fatfs_volume.c)、
owner APIは[nihos_fatfs_volume.h](../../include/nihos_fatfs_volume.h)。
hostで実FatFs/VFSへ接続し、RV32 object compileまで確認する。native SD ownerへの接続は次の段階とする。

## 選択と範囲

512 B sector、最大2^32 sectorのdeviceを受け取る。AUTOは有効なsuperfloppyを優先し、
それ以外では有効なFAT/exFAT primary volumeが1つだけある場合に選ぶ。
複数候補は先頭を暗黙採用せずAmbiguousにする。明示選択は物理MBR slot 1..4である。
WHOLEはsuperfloppyのみを調べ、MBRへfallbackしない。

MBRでは全4 entryのstatus、空entry、非zeroのfirst/count、device内の終端、全組合せの重複を調べる。
未選択のLinux等のentryも範囲検査する。これが完了する前にpartitionのVBRを読まない。
終端は64 bitと減算によって検査し、32 bitのfirst+count循環を許さない。
GPT protective entryとextended partitionを見つけたらUnsupportedで止める。EBR chainは辿らない。

partition typeは探索候補の制限であり、FSの正当性を保証しない。
FAT12/16/32はcluster数、reserved/FAT/root/dataの配置、FAT容量とroot clusterを検査する。
exFATはzero領域、version、sector/cluster shift、単一FAT、FAT/heapの配置と容量、root clusterを検査する。
制限値は固定FatFs R0.16の`check_fs` / `mount_volume`に合わせる。全FS構造やexFAT boot checksumの完全検証ではない。
最終mountと既存の循環chain検査を引き続き必要とする。

成功時の`first`はownerが選んだ物理開始位置、`count`はVBRの宣言長、`container_count`はその外側の領域長である。
diskioへは`first/count`を渡して未使用tailを除く。BPB hidden sectors / exFAT PartitionOffsetをI/O addressに使わない。
VFAT LFNの解釈や別名同一性は既存FatFs/guarded Backendの責務で、partition選択には入れない。

複数partitionを発見できることと、複数FSを同時mountできることは別である。
現diskioの`active`とBackendの`live`は単一owner / drive 0の状態を持つ。
切替は旧VFS handleの失効、RPC drain、FS destroyとdisk detachの後、新epochで行う。
同時mountへ広げる際はdrive別のbinding/sessionとmount別の課金・pin・失効範囲を設計し、
単一globalをpartitionごとに書き換えて実現しない。

## 資源とsession

scratch512 Bは呼出元が保持し、callbackは既存diskioと同じ「DMA fence確認後だけ戻る」契約を持つ。
通常returnでは成功・失敗ともscratchをclearし、outputは成功時だけ公開する。
部分的なcallback書込みや途中のI/O失敗から選択結果を公開しない。readは最大5 sectorである。
無効引数はI/O前に拒否し、scratchとoutputの重複も拒否する。

結果はcapabilityやカード固有IDではない。ownerはprobe→bind→mountを同一card/controller session内で実行する。
間に抜去・I/O faultがあれば結果を捨て、旧objectを失効させてから別世代でやり直す。
未確認DMA fenceのcallbackが戻らない場合は、親領域とpinを保持する従来のquarantine契約を維持する。

## 次のnative接続の順序

1. 既存I/O寿命試験後のcontrollerはfaulted/removedである。旧`runtimeBegin`で使い回さず、
   quiescenceとdescriptor切離しを確認して明示的に新しいcard sessionを作る。通知ticketは巻き戻さない。
2. brokerのservice parentを予約・pinし、disk/backendとprobe scratchを配置する。
   512 Bのscratchをそのまま4 KiB task stackへ追加しない。最終linkとstackを再監査する。
3. fenced `nih_fatfs_native_read`でprobeし、同じsessionのまま新しいdisk epochでbindし、private FatFsをmountする。
   エラー時もcallbackの停止確認より前にscratch/parentを回収しない。
4. VFS/RPCへ接続し、取消・kernel停止・旧世代拒否・drain・全回収を実カードで再確認する。
   mountが失敗しただけの試験をFatFs file-read成功へ数えない。

現在のnative起動試験はSD上のlittlefs fixtureを必須としている。
FAT/exFATカード用candidateでは、専用opt-inとsource付きログ契約でこの前提を分ける必要がある。
既存littlefsの判定を無条件に緩めたり、カードをformatして同じ試験に見せたりしない。
既存controller exportの容量はu32なので、generic probeの2^32-sector境界試験をnative対応容量と同一視しない。

既存の新session準備には、ownerの未完了lease、通知ticket、現sessionの有効状態、
controller quiescenceと世代上限をまとめて確認するgateを追加した。
停止未確認やquarantine中はcontroller stateの置換とremoval latchのclearへ進まない。
hostで各拒否条件と実ownerのquarantineを確認し、既存SD抜去構成のnative ELF監査を通した。
このgate単体ではprobe/bind/mountを行わない。

### 新sessionの入口

FatFs opt-in build向けに、既存controllerの停止確認後に新しいcard sessionを開始し、
sector数と単調増加するgenerationを返す内部owner APIを追加した。終了時はgenerationの一致、
未完了I/Oなし、通知windowが閉じていること、controllerの完全なquiescenceを要求する。
初期化失敗時はcontrollerの停止を未確認とし、再試行を拒否する。
既存FatFs fixture構成と既存SD抜去構成のnative ELF監査を通した。
FatFs構成のELF SHA-256は`336d7976f0a1d31b01e77ebe4f0f55f6b7796b15b5aab1b897ff583f67e1d280`。
入口そのものの実機実行、volume probe/bind/mount、caller側のFS teardownはまだ未接続である。

### 読取り専用の実カード候補

`NIHOS_NATIVE_FATFS_SD=1`を既存`FATFS_RPC=1`構成へ追加すると、組込みfixtureの終了後に
`NIHOS_FATFS_SD_READY`で待つ。既存littlefsカードからFAT/exFATカードへの交換完了をoperatorが通知し、
runnerのprivate出力に`card-inserted.json`（`operator_confirmed: true`）をatomicに作成した後だけ、
USBの`S`を受けて新sessionを開始する。交換前からprobeを繰り返す経路にはしない。

probe→選択viewのbind→guarded FatFs mountを接続した。rootを最大64 entry調べ、
hidden/system/directoryを除く非empty・1 MiB以下のfileを1つ選び、最大4 KiBを2回読む。
file名はCRCのみ、内容はCRCとbyte数のみを記録する。この比較は同一prefixの自己整合性であり、
外部の既知content hashとの一致ではない。実カードをnative VFS/RPCへ接続した資格にも数えない。

workspaceは`.vfs`へ32 KiBを課金してpinし、FS destroy・disk detach・世代一致のsession終了後だけ
clear/unpin/freeする。boot stackのpaintとguardも別recordで確認する。
card pipeline、source profile、cleanup recordが欠けた結果は採取側で拒否する。
hostでは5形式について各3回の正常読取りと3位置のI/O失敗後のteardownを検査した。
native候補のlink/配置監査も通したが、この段階ではまだ実カードで実行していない。

このcandidateはカード交換を伴う1回の起動として採取する。Flashは16 MiB全面のdigest一致まで復元し、
別カードが残っている間は元firmwareへのresetを保留してROM download状態を保つ。
元のカードへ戻してから通常起動する。カードのformatや書込みは含まない。

[host検証の記録](../measurements/2026-10-28-volume-admission-host.md)にfixture hash、負例と未確認範囲を保存する。
