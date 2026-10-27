# ストア公開順序のクラッシュ復旧モデル

2026-10-27。`codex/store-crash-model`、実装commit `c7ec6fd`。
実機を使わずに、immutable payloadと交互に更新する2個のrootによる公開順序を検査するホストモデルを実装した。
4,212通りの中断条件と、成功通知後の18通りの再起動をDebug／ReleaseSafeの両方で検査した。
これは[unified log store計画](../planning/unified-log-store.md)の初期モデルで、実際のlog形式や新filesystemの採用を確定するものではない。

## 実装した範囲

[COWモデル](../../src/storage/cow_model.zig)は1 writerを前提とし、objectの置換・削除・縮小truncate・任意offsetからの読取り・rollbackを扱う。
transaction中の変更は、commit成功まで現在の読取りviewへ公開しない。容量不足とobject数の超過は、その操作による書込みの前に拒否する。
I/O失敗後はinstanceをfault状態にし、復旧前の再利用を拒否する。世代番号は64 bitで、最大値からwrapさせない。

commitはpayloadのsync、次世代rootの書込み、rootを含むsyncの順で進め、最後のsyncが成功してからacknowledgeする。
rootには世代、object map、長さ、所在とchecksumを含める。復旧ではrootのchecksum、版、bounds、重複ID、extentの重なり、
参照先payloadのchecksumを検査し、有効な最大世代を選ぶ。壊れた媒体を暗黙に初期化しない。

object mapは最大8件、root／payloadの作業単位は4 KiBとした。
通常の中断試験は48 KiBの仮想媒体を使い、別の96 KiB fixtureで71,681 Bのobjectもcommit・再読取りした。
64 KiBをtransactionの暗黙上限にはしていない。
これらは試験用の有限条件で、16 GB媒体のmap構造や将来のon-media形式・最大file長ではない。

## 故障モデルと結果

[媒体モデル](../../src/storage/model_media.zig)はvolatile cacheとstable imageを分ける。
成功したsyncはそれ以前のdirty sectorをすべて永続化する。sync前にも書込みが永続化し得る。
電源断はcacheを失わせ、成功したsync以前のstable bytesは保持するという前提である。

未同期書込みの永続化は「なし／交互sector／すべて」の3通り、flush順序は昇順／降順の2通りとした。
cache-writeの512 B sector、sync開始、dirty-sector flushの各eventを中断する。
tear位置は各eventについて0／1／31／255／511／512 Bを試す。全byte位置や全書込み順列の網羅ではない。

|対象|正常経路のevent数|中断ケース|成功通知後の再起動|
|---|---:|---:|---:|
|object置換・追加・削除|82|2,952|6|
|縮小truncate・削除・空object追加|18|648|6|
|最初のroot公開|17|612|6|
|合計|117|4,212|18|

変更時の中断では、全objectが旧世代か新世代に揃うことを確認する。
成功通知後は必ず新世代を回復する。最初の公開が中断した場合は、完全な初期root、未初期化、または破損として扱い、部分的なrootをmountしない。
protocolが生成したchecksum整合rootには、復旧時に破棄する必要のある未永続payloadを参照させない。

追加の検査は、rootの交互更新、rollbackで残る未公開領域の再利用、部分読取り、容量・object admission、
不正な版・範囲・ID・payload、readエラー、世代枯渇である。

## 不正な実装を検出する負例

dataだけを保存してrootをsyncしないbackendを故意に使うと、成功通知した世代3が再起動後に世代2へ戻る。
rootをpayloadより先に保存した媒体では、復旧で旧世代へ戻れても、公開rootの参照先に未永続dataが残ることを検出する。

さらに、実装からpayload側のsyncを1行だけ除いた変異版へ同じ試験を実行した。
未同期書込みを保存しない設定・昇順flush・event 48・512 B完了時の中断で、rootだけが永続化し、復旧は世代2へ戻った。
`DanglingPublishedRoot`で不合格になった。dataの保存と、所在を示すmetadataの保存を両方gateにする必要がある。
これは故意に不正にしたモデルの検出結果で、既存SDドライバの不具合を発見したという意味ではない。

## 検証と再現

Zig Debug／ReleaseSafe各197件（追加13件）、Python 168件、format／ZLint／ShellCheck、
RV32 broker compile、既存6種類のnative ELF linkと配置監査が合格した。
このモデルはnative起動経路へ接続しておらず、[実機待ちのFlash配置候補](2026-10-27-native-cold-flash.md)は別worktreeの固定imageとして維持した。

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
python3 -m unittest discover -s tools -p '*test.py'
sh tools/run-static-analysis.sh
```

[構造化結果](2026-10-27-store-crash-model.json)と
[source・ログ・変異patchのarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-crash-model-host)を保存し、21ファイルのSHA-256を再照合した。
負例は次で再実行できる。このcommandはexit code 1と`DanglingPublishedRoot`が期待結果となる。

```sh
.tools/zig-0.17.0/zig test \
  /Users/masanork/Documents/Codex/2026-10-27/nihos-store-crash-model-host/no-payload-barrier-diagnostic/cow_model_test.zig \
  -O safe --test-filter 'every write and sync event'
```

## 次のgate

現時点ではmemory-backed媒体だけで、実fileのfsync、SD／NOR、erase、GC、reader pin、永続index、
checkpointとbounded tail replayを扱わない。復旧時に参照payloadを読む方法は、16 GB媒体のmount方法には使えない。
先にfile-backed backend、容量不足時のclean-space admissionとreader pinを含むGC、on-media mapと回復量の上限を追加する。

VFSの部分write・伸長truncate・metadata操作、SQLite `PERSIST`／FULL、WALは後続とする。
このモデルを根拠にSQLiteのatomic-write capabilityや物理カードの電源断耐性を宣言しない。
