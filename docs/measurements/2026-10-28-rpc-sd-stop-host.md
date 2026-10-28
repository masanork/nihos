# RPC取消とSD controller停止の結合

2026-10-28、source `638e04c`。SD VFS/RPC構成へ`CancelRelay`を接続した。
ordinary ownerがRPC read ticketを一度だけ捕捉し、controller待機・copy前・completionで
resident通知を調べ、そのreadに結び付いたSD ticketへだけ取消を送る。
[構造化結果](2026-10-28-rpc-sd-stop-host.json)と
[host/target監査の生結果](evidence/2026-10-28-rpc-sd-stop-host/)を保存した。

IRQ/他hartは既存のresident atomicへRPC取消または停止済みclientの通知を行うだけである。
resident hook 2関数はPSRAM、FS、MMIO停止、allocatorへ触れない。
停止は通常のcontroller ownerが行い、device idle、descriptor切離し、cache返却が揃うまで
block-owner leaseを回収しない。停止証明が失敗すれば従来どおりQuarantinedを保持し、
native fixtureは通常のFS errorとして戻らない。

|検査|host結果|
|---|---|
|RPC取消のみをCMD17発行点で通知|実controller modelがcopy前に停止、fenceとlease回収、replyは-125で全clear|
|kernel停止済みclientの通知のみ|同じ停止経路へ進み、queued request/replyを破棄|
|client pagesの回収|停止通知後に先に回収してもservice parentはpinを保持し、早期free/retireを拒否|
|不健全mount|cached read/openとclient再bindを拒否、FS終了後に全poolを回収|
|旧ticket|RPC windowの終了・再利用後のsource、およびSD ticket再利用後のrelayを拒否|
|停止失敗|reset/FSM/descriptor/cacheの4条件×relay有無でquarantineとlease保持|

FAT12/16/32・MBR FAT32・exFAT各fixtureの2経路、計10件を追加し、全109シナリオが通過した。
実C card context、guarded FatFs、Zig VFS/RPC、development broker、実controller codeを結合した。
controllerのMMIO/cache/DMA callbackはhost modelであり、hardwareを実行した試験ではない。
exitは停止済みactorを表す通知注入であり、この結合試験自体はkernelによる実task停止を実行しない。
取消とdevice失敗を別々に注入していた[前段の試験](2026-10-28-fatfs-card-removal-host.md)も保持する。
新しい10件ではRPC通知だけを注入し、controller側の停止結果を経てCへ-2が返る。

待機中のrelayだけを省きcompletion時のrelayを残す負例は、controllerがfinishDmaへ到達して失敗した。
応答の後処理だけで取消扱いにする実装を、この試験のcontroller停止合格に数えない。
旧RPC sourceや旧SD targetが次の転送へ作用しない性質もZigで検査した。
Zig Debug/ReleaseSafe、Python237件、変更したZig 9ファイルのfmt/ZLintが通過した。
最終host採取のsource指紋は直接49ファイル、disk試験24ファイルとも一致し、全fixtureの前後hashも一致した。

native SD構成はimage/ELF/frame監査、従来の組込みFatFs構成は回帰ELF/frame監査を通過した。
imageは851,648 B。card profile v4、immutable mode3、resident read hook 2関数を要求する。
旧ELFへのmetadataだけのrelay有効化、および新ELFを旧profileで隠す操作はどちらも拒否した。
旧v3候補のELFと[前回の実機log](2026-10-28-fatfs-card-rpc-physical.md)は新checkerでも再検査でき、
保存済みreportと完全一致した。新しい実機runとしては数えていない。

RV32 card context 26,104 B、service parent使用44,928 B・課金65,536 B、client別課金8,192 Bを維持する。
通知stateもresidentの28 Bのままで、relayはordinary ownerの一時controlである。
source archive、image/ELF、manifest、loaderはprivate buildへ固定した。

既存native workloadはsector fence後の取消・client停止を行う経路のままである。
今回のbinaryに新たな発行後abortの資格試験phaseはなく、実機へも書き込んでいない。
静的なrelay有効flagを転送途中abortの合格へ変えず、checkerも`controller_abort_qualified=false`を返す。
device completion後の取消ではreplyをclearするだけの場合もあり、rollbackや即時abortを保証しない。
実転送途中の停止、mount中の実カード抜去、card-detect IRQ登録、総stack上限、書込み・SQLite永続化・
clean POR・電断復旧は別gateである。
