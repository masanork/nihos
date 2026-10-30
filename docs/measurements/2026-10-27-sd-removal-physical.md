# 実カードの抜去・再挿入とSDMMCの停止確認

2026-10-27、native実装 `b21e114`。operatorによる同じmicroSDの抜去・再挿入と、
実SDMMCのread error、停止、lease返却、再sessionの照合が成功した。
[構造化証跡](2026-10-27-sd-removal-physical.json)にsource/image hash、operator確認と生ログhashを保存した。

Tab5はESP32-P4 rev1.3、MAC `e8:f6:0a:e2:e8:9c`。appは825,280 B、
SHA-256 `27450e69561ec58b4286513c9bc7e3a4333e82aa0618a84c2292305b7a6d78d5`。
`NIHOS_NATIVE_SD_REMOVAL=1`の固定候補で、通常のSMP/SD/storage/SQLite/broker試験と取消通知試験を終えた後に実施した。
SDへの書込みやformatは行っていない。

## 実際に確認した順序

1. 新しい1-bit / 400 kHz sessionでLBA 0を読み、`NIHOS_SD_REMOVE_READY`を出す。
2. operatorがカードを抜き、「カードを外した」と確認する。
3. 抜去までの正常readは5,272回。次のCMD17がresponse timeout (`interrupts=0x100`)で失敗する。
4. driverはDMA reset self-clear、IDMAC idle、mask無効化、descriptor切離し、cache返却を確認する。
   destinationは`0xa5`のまま、leaseを回収し、抜去latchで次の発行を拒否する。
5. `NIHOS_SD_INSERT_READY`の後、operatorが同じカードを戻し、「カードを戻したよ」と確認する。
6. quiescentな旧sessionから新しいcard/controller sessionを作り、世代が3→4へ進む。
   容量が一致し、LBA 0を2回読みCRC `0x9022e83d`が一致する。旧ticketを2件拒否する。

失敗sessionのcontroller enable/reset、bus mode、IDMAC FSM、両interrupt mask、descriptor baseとwordは全て0だった。
容量とCRCはfixtureの入力照合であり、カードの唯一IDではない。
接点断の瞬間をcard-detect IRQで測っていないため、物理抜去がDMA beatの途中だったと保証する記録でもない。

## 失敗した先行試行と復元

attempt 1はFlash退避中、3,821,568 Bの受信時点でUSBが切れ、`SerialException: Errno 6 Device not configured`で終了した。
candidateの書込み前で、backup fileは0 B、元のFlashは変更していない。この試行を合格に含めない。

attempt 2は同一exclusive FDで、Flash 16 MiBをprivateに退避し、候補の事前/事後照合と試験を実行した。
終了後に元のloader/app範囲へ復元し、`verify_flash 0 flash-before.bin`で16 MiB全体のdigest一致を確認した。
退避ファイルのSHA-256は`fbef6cdd19d1b815d1e70da8904d03e4f0e7d7568122e2bac96166916384d58e`。
source・両試行・operator確認・復元結果は
[固定package](/Users/masanork/Documents/Codex/2026-10-27/nihos-sd-manual-qualification-candidate)に保存した。
privateなFlash backup本体を公開artifactには含めない。

本体のcold power-onは別試験であり、この実カード試験の合格に含めていない。
hardware上の停止/cache失敗注入、card-detect IRQ、FatFs BackendとVFS/RPCの接続も残る。
