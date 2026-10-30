# Guarded FatFs Backendと実VFSのhost接続

2026-10-28。`codex/vfs-native-lifetimes`の`f2341df`を基点に、guarded FatFs Backendを
実際のZig VFSへ接続した。実行はhost上の同期sector callback、C側はASan / UBSan、
Zig側はReleaseSafeである。serial接続・Flash書込み・実カードmount・電源操作は行っていない。

[結果JSON](2026-10-28-fatfs-vfs-host.json)に58ケースの観測値、source/upstream/object hash、
入力imageの前後hashと、target ELFから求めたworkspaceサイズを保存した。
再実行は`python3 tools/check-fatfs-backend.py`。disk-only試験も同じrunnerから実行する。
CIはこのrunnerと両JSONの保存へ更新したが、今回の成功はlocal実行である。

|確認|結果|
|---|---|
|媒体構成|FAT12 / FAT16 / FAT32 / MBR FAT32 / exFAT全てで成功|
|file chain|self-cycle、2-node-cycle、短縮chainをguarded lookupで拒否|
|directory|root/親の循環、ancestor aliasを拒否。exFAT overlayはentry checksumも再計算|
|file identity|別の空ファイルは別ID、long/short/case aliasは同じID、親dir・Unicode正規化形の違いは別ID|
|lookup→open|検証済みFILを固定slotに保持し、openは追加I/Oも名前の再解決もしない|
|VFS|principal・root・write権限をI/O前に検査し、I/O失敗でmountをfaultedにする|
|remount|VFS detach→private token/FS破棄→disk新epoch。旧root/file/backend epochはI/Oなしで拒否|
|cacheと失効|一度読んだfileでも失効通知後はcached bytesを返さず、新たなsector I/Oも行わない|
|出力|途中I/O失敗時はpublic readのcount 0、出力buffer不変|
|寿命|FSによるbinding retain中とcallback中のdisk detachを拒否。終了時はworkspaceをclear|
|constructor|容量不足・非整列・diskとの重なり・旧epoch・既存binding保持を拒否|
|boot policy|選択済み領域のVBR署名・sector size・宣言長を確認し、不正値を拒否|
|large file|guarded Backend経由でもexFATの4 GiB超offsetを含む3か所のmarkerを確認|
|source image|全5 imageの全体SHA-256が前後一致。fault overlayを書き戻さない|

case数はrunnerの58回のscenario実行を数え、各byte比較のassertion数を別テスト数には数えていない。
故障注入の初期試行ではhost overlayの中間pointer計算をUBSanが拒否した。
offset差を括弧で先に計算する修正後の、最終source一致runだけを今回の成功記録に採用した。

|RV32 layout|bytes|
|---|---:|
|disk workspace|4,152|
|Backend（FATFS、16 open＋1 pending、read staging、path等）|15,712|
|VFS表（1 mount / 32 handle slot / 16 I/O lease）|3,520|
|上記合計|23,384|

これは型の固定領域であり、global、upstream code/rodata、LFNやcall stack、RPC buffer、
allocator metadataと最終配置の合格ではない。現行8 KiB littlefs workspaceへは収まらない。
C Backend、shimを含むFatFs、Unicode、実VFS/adapterのRV32 object compileが成功した。
最終firmwareへのlinkや実行は行っていない。

Zig Debug / ReleaseSafe各229件、Python 184件、format / ZLint / ShellCheckと既存6構成のnative ELF監査も成功した。
guardの`safety.[ch]`はhost VFS PR #3の`542b3a3`と同一で、同branchを変更していない。
VFS core/testもそのcommitを起点とし、このbranchではlookup/openのI/O等の失敗後にmountをfaultedへ進める。

単一owner、immutable mounted media、volume rootを前提とする。partition領域の選択はtrusted callerが行う。
RPCの取消/kill時のpin、card-detect IRQからのownerへの失効伝達、複数FSのruntime routing、subtree root、
最終メモリ/stack admissionは残る。同期callbackの全returnでDMA fenceが成立するという契約も必要で、
host mockの成功をsiliconの停止/cache失敗注入の証明にはしない。
clean power-on、実カードFatFs、永続SQLite、書込み・電断耐性の合格は追加していない。
