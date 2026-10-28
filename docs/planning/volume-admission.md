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

[host検証の記録](../measurements/2026-10-28-volume-admission-host.md)にfixture hash、負例と未確認範囲を保存する。
