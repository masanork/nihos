# 0045: stopped storage clientの未完了RPCをownerで回収する

2026-10-26。Status: Accepted（opt-in native qualification）。
[0044](0044-native-storage-owner-and-copied-rpc.md)の一対一copy RPCを拡張する。

## 判断

clientの通常EXITと強制終了は、schedulerがtaskをexitedにした後、同じresident tombstone hookへ渡す。
IRQ/bootstrapのMIEを止めた区間では、handle照合・atomic公開・IPI通知だけを行う。
FSのclose/destroyやPSRAM queueの走査は行わない。allocation ledgerの回収とstorageのacknowledgementが
両方済むまでtaskをreapしない。

ownerは処理中の同期操作を終えてからendpointを閉じる。SD controller/DMAを途中で破棄しない。
copy型の要求/応答だけを使うため、clientのstackやbufferへの書込みは発生しない。
`Owner.clientExited(queues)`はendpointを閉じ、open fileをreleaseし、未実行requestと未受信responseを
破棄して件数を保持する。二度目の呼出しはreleaseを繰り返さず、閉じたendpointへのdispatchは拒否する。
backendのreleaseが失敗した場合もendpointを再開しない。

response queueのconsumer cursorをownerが引き継ぐのは、client停止のacquire確認後だけである。
request producerも停止しており、owner自身のdispatchも戻っていることを呼出し条件とする。
生きたclientに対する並行cancel APIではない。slot内の残存byteは、両taskのreap後にIPC予約領域全体を
zeroにして検証する。FS領域のzero検証はowner側のdestroy直後に行う。

## 資格試験

従来の全ファイル読取り・CRC・境界拒否に続けて2 readを送る。最初のreplyを未受信のまま残し、
次の512 B readを同期block read完了後・RPC response publish前のbarrierで待機させる。
clientはこのbarrierを確認して後続requestを2件積み、blockedになる。
CPU1 bootstrapがそのclientをexit code -98でterminateしてtombstoneを公開する。
ownerはbarrierを抜け、実行中readのreplyをpublishした後、request 2件・reply 2件を破棄する。
CPU1 ledgerのforcedが1増えること、file release、再dispatch拒否、両領域消去、task reapも判定する。
service manifest version 2のlogはこの追加判定を必須とし、version 1の過去ログも従来条件で読める。

barrierはread完了後にある。転送中のDMA abort、任意命令位置でのkill、hot removal、I/O timeoutや
複数clientの取消しを資格確認するものではない。一般アプリ向けkill syscallや権限分離も追加しない。
