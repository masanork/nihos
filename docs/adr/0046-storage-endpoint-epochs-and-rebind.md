# 0046: storage endpointを世代付きで再接続する

2026-10-26。Status: Accepted（opt-in native qualification）。
[0045](0045-storage-client-cancellation.md)の強制終了後、同じowner/mountを保持したまま新clientを接続する。

## 判断

要求・応答に32-bit epochを加える。ownerがbindingごとにepochを増やし、新bindingのsequenceは1から始める。
古いepochの要求はbackendとsequence更新の前に-13で拒否し、応答には現在のepochを入れる。
clientも応答epochを確認する。同じsequenceの古い応答が新しい要求を完了させてはいけない。
epoch zeroとwrapは許さず、最大値に達したendpointは再接続できない。

epochは寿命の区別であり、権限の証明ではない。ownerは引き続きkernel由来のclient identityを固定して使う。
メッセージが指定するownerへ処理を転送しない。共有machine-mode内のtrusted fixtureという前提は変わらない。

`Owner.rebind(client, queues)`は旧clientが停止し、owner releaseが成功し、両queueが空の時だけ許可する。
生きたendpoint、client zero、同じclient、残存message、release失敗、epoch枯渇は拒否する。
backendのworkspaceとfile token counterは引き継ぐ。旧tokenを新openへ再利用しない。
FS workspaceをdestroy/initしてtokenを1へ戻す経路は、この再接続APIの対象にしない。

## Native lifecycle

CPU1 clientをexit -98で強制終了し、allocation cleanupとstorage release/drainのack後にreapする。
schedulerは同じslot/4 KiB stackをgeneration 4で再利用する。最初のclientはgeneration 3。
再登録時にresident handshakeを初期化し、新しいkernel handleを公開する。
ownerは新しいC identityを待ってepoch 2へrebindし、replacement clientを起こす。
古いkernel handleからのexit通知は現handleと一致しないため無視する。

fixtureは古いepochの要求、同じsequenceを持つ古いepochの応答、旧file handleを新openの前後で試す。
古い応答はownerが意図的にqueueへ注入する合成fixtureであり、実際の遅延転送の観測とは区別する。
replacementは同じファイルを全読取りしてCRCを確認し、open handleを残した通常EXITで終了する。
ownerが二度目のreleaseとFS destroyを済ませ、両taskをreapした後にIPC予約領域を消去する。

cleanup ackは1が旧clientの再利用許可、2が最終owner/replacementのreap許可を表す。
IRQは引き続きresident flagsとschedulerだけを扱う。PSRAM queue・FS操作はtask contextで行う。
service manifest version 3は追加generation/epoch拒否・再読取り・CPU1の追加task台帳を必須にする。

## 対象外

owner task/controller自体の再起動、FS workspace破棄後のtoken管理、電源をまたぐepoch、
複数同時client、一般アプリ向けsyscall/権限分離は別の設計が必要である。
SD DMAの途中abort、hot removal、任意命令位置でのkill、任意workerとのpreemptionは資格試験の対象外。
