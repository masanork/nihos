# 実機FS接続前のchain・identity・I/O寿命契約

2026年10月27日。PR #3のhost packageへ、指摘された3項目の実装と回帰試験を追加した。
対象はread-only FatFs shimとowner側VFSの寿命管理。native driverや実機への接続はまだ行っていない。
以前の[Linux記録](2026-10-27-fatfs-linux-host.md)は、対策前のnegative controlとしてそのまま残す。

## 循環chainの検出と停止

[safety.c](../../probes/fatfs/safety.c)は、source hash固定したFatFsのtranslation unitをincludeする薄いshimである。
upstreamのsource自体は公式patch 2の状態から変更せず、privateなchain/名前解決関数を同じunit内で使う。
FatFs更新時にはこの依存を再検証する。通常のopenとdirectory列挙はguardを通す。

- fileと各containing directoryのchainを、Brent法で定数workspaceを使って検査する。
- 自己循環、2節点循環、不正・予約cluster、必要長より短いchainを`Corrupt`として拒否する。
- directory祖先へのaliasも検査する。FATだけでなく、entry-set checksumを正しく再計算したexFATの祖先aliasも拒否する。
- 1操作で共有する初期8,192 stepのbudgetと取消callbackを設ける。上限到達は`BudgetExceeded`、取消は`Cancelled`とし、
  正常だが長いchainを壊れていると誤判定しない。directory ancestryは16段までとする。
- exFAT NoFatChain extentは開始位置・長さ・volume範囲を検査し、連続した4 GiB fileを全cluster走査しない。
- openがguardで失敗した場合はfileを閉じ、内容の転送を始めない。raw FatFsの循環read成功は比較用に残す。

これはmount後のfile/directory単位の検査であり、volume全体のfsck、allocation bitmap、cross-link検査ではない。
mount自身のmetadataアクセスには下位I/O budgetも必要で、host試験ではdisk read上限とsubprocess deadlineを併用する。
native側の最悪実行時間、途中から再開する検査、実driver内の取消は別途測定・接続する。

## 空fileと別名の同一性

[safety.h](../../probes/fatfs/safety.h)のidentityは、canonicalな親directoryの開始clusterとdirectory entry offsetの組である。
FATではSFN entry、exFATではfile entry-setの開始位置を使い、file自身のdata clusterには依存しない。
outer VFSのmount世代と組み合わせて用いる。

実imageで、異なる空fileはdata clusterが共に0でも別ID、LFN/8.3別名・case違いは同じID、
別directoryの同名fileは別IDになることを検査した。結合濁点を含む別名を勝手にUnicode正規化して統合しない。
FAT12/16のroot entryではidentity key 0も有効であり、coreでも0を無効file扱いしない試験を追加した。

このidentityはread-only mount内での同一性である。再mountは別世代にし、外部writerを同時に使わない。
将来のdelete/createやentry再利用に対する永続IDとしてそのまま使わない。
native Backendはこのkeyをownedなfile recordへ対応付け、lookup/open間も同じowner/leaseで保護する必要がある。

## DMA取消・抜去時の寿命管理

[io_leases.zig](../../src/fs/io_leases.zig)を[VFS core](../../src/fs/vfs.zig)へ接続した。
固定16要求のledgerに、request世代、mount/file世代、principal、buffer leaseを保持する。
最初のserviceは、複数mountが同じcontrollerを共有する場合も考え、active転送を全体で一つに制限する。

```text
queued → active → stopping → terminal → take/discard → slot再利用
   └─ 未発行の取消・抜去 ─────→ terminal
```

activeな取消・抜去・client終了だけではbufferを返さない。driver ownerが以下を全て確認した後に限りterminalへ進める。

1. deviceがidleで、以後bufferへアクセスしない。
2. descriptorの所有権が返り、遅れた処理が新しい要求へ混入しない。
3. 必要なcache処理が終わり、CPUへ所有権が戻った。

一つでも未確認なら`Busy`でleaseを保持する。file close、mount detach、bufferの重複leaseも拒否する。
terminal後もcompletionを回収するまで資源を保持し、世代を進める。遅延・重複completionは旧世代として拒否する。
driverが転送の成功を報告しても、先に取消・抜去が受理されていれば内容を成功結果として公開しない。
cleanに停止できた取消後はmountを利用可能に保ち、取消と無関係なI/O失敗はmountをfaultedにする。

host試験では、queued取消、active取消、stop失敗、部分fence、抜去、client死亡、late completion、
slot再利用、要求枠満杯、世代上限、foreign principalを検査した。
取消・抜去・完了の6順序を試し、終端結果とlease返却が一度だけになることを確認した。

## 検証結果とnativeへの接続条件

[FatFs全case](evidence/2026-10-27-fatfs-safety-host.json)と
[Zig source identity・寿命試験の範囲](evidence/2026-10-27-vfs-io-lifetimes.json)を保存した。
macOSではFatFs 200 case、ASan/UBSan、元imageの不変性、独立したFAT fsckが成功。
Zig Debug/ReleaseSafeは各183件、うちlease 6件・VFS 28件が成功。fmt/ZLintも成功した。

native driverへの接続では、以下の順序を守る。

1. service所有のbufferを確保・pinし、世代つきleaseを`retainRead`へ渡す。
   client taskのheapをDMA中にそのまま回収できる設計にはしない。
2. `startRead`成功後にだけdriverへ発行する。request世代をdescriptor/IRQ処理と対応付ける。
3. 取消・抜去では`readStopRequired`に従ってstop/resetし、新規発行と旧IRQを止める。
   停止失敗時はcontrollerを隔離し、leaseを保持する。
4. 実際のdevice/descriptor/cache状態を確認して`finishRead`へfenceを渡す。
   boolを無条件にtrueへすることで停止確認を代用しない。
5. `takeRead`はcompletedのときだけ内容をclientへ公開し、他の結果では内容を破棄する。
   client死亡時はtrusted ownerがterminal後に`discardRead`し、それからbufferを返す。

既存native branchにはSDMMCの`stopDma`と`finishDma`があるが、このledgerとの接続は未実施。
hardware IRQがsoftware request世代を自動的に持つわけではないため、再発行前のmask/drainとresetの実機確認が残る。
hostで寿命契約を検証したことを、実DMAの停止・cache整合・抜去の実機合格とは扱わない。
