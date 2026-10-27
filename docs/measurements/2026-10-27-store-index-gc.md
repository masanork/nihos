# indexページの回収とreader snapshot保護

2026-10-27。`codex/store-crash-model`、実装commit `2298194`、ack境界の追加検査を含むsource snapshot `736cb51`。
[範囲checksumモデル](2026-10-27-store-range-checksum.md)へ、参照されていないindexページの再利用を追加した。
3ページのpoolで6,000回の更新、16 GiB疎fileの256ページpoolで640回のleaf更新を通した。
payloadは依然append-onlyで、その移動・回収を実装したわけではない。
実SDへの書込み、Tab5上の実行、実電源断、SQLite永続VFSの検証も含まない。

## 保護対象と再利用

[checkpoint_model.zig](../../src/storage/checkpoint_model.zig)は次のrootが参照するleafを再利用しない。

- 最新の公開root
- もう一方の有効なdisk root
- 進行中transactionのstaged root
- 使用中のreader snapshot。defaultは2枠

free pageはRAM上のroot参照から判定する。媒体全体のbitmapや、page数に比例するRAM配列は追加していない。
put／removeは未参照ページへleafをCOWで書く。古いstaged leafだけが参照を失った場合も再利用できる。
新しいrootのsync成功後にだけdiskの旧rootをretireし、次回以降の割当てで、そのrootだけが参照していたpageを使えるようにする。

recoverは最新候補を選ぶと同時に、もう一方の有効なrootも保持する。
片方だけを覚えて再利用を始めると、旧rootのfallback用leafまで上書きし得るためである。
rootの`index_next`は割当て済み位置のhigh-water markとして保ち、再利用時に値を巻き戻さない。
disk形式はversion 2のままで、既存のgeometry・範囲検査を満たす。

この実験は通常のhost fileへの上書きを使う。erase-before-writeが必要なNOR用の回収手順にはしていない。
root参照の走査はCPU処理であり、native上のlatencyは未測定。

## 回収用の余裕とNoSpace

`collectIndex()`はrootだけをcheckpointし、旧disk rootをretireする。
新規leafやpayload pageを必要としないため、indexの空きが0でも実行できる。
これはindex専用の非移動型回収であり、payload cleanerのcopy reserveを解決したものではない。
transaction中の呼出しは`Busy`。I/Oエラー後に後続書込みを続行しない。

pinされたrootが全pageを必要としていれば回収後も空きは戻らず、put／removeは`NoSpace`になる。
容量不足のadmissionではpayloadやleafを書き始めない。pinを解放すると、その参照だけが保持していたpageが再利用可能になる。
pinsのない旧disk rootだけが空きを塞いでいる場合は、root-only checkpointで空きを戻せる。

defaultの128 leaf、reader 2枠では、保護対象の最大数は
`(current + retained + staged + reader 2) × 128 = 640 page`。
4,096 pageのindex poolはこの上限を上回り、正しいroot参照だけでpool全体を使い切ることはない。
小さなpoolも実験用に許可し、そこでのbackpressureと回収を試験している。
payload残量やgenerationの上限による失敗は別に残る。

## readerの契約

`pin()`は現在の公開rootを固定し、`readPinned()`はその世代のkeyを読む。
writerが更新・削除・回収しても、pinされたleafは再利用しない。
`release()`後は同じslotの次のpinに別tokenを割り当て、古いhandleのread／二重releaseを`InvalidReader`で拒否する。
枠が埋まると`ReaderLimit`。I/O fault後もreleaseは許可する。

handleはstore instanceの生存期間内で使うホスト実験用である。
公開capability ABI、異なるinstanceをまたぐ認証、再起動後のsnapshot保持ではない。
呼出しはsingle ownerで直列化する。CPU間の同時呼出しに対するlockやVFS handleとの接続は追加していない。

## メモリと回復量

|項目|今回|前回|
|---|---:|---:|
|arm64のstore状態|14,544 B|8,280 B|
|RV32 compile上のstore状態|14,536 B|8,272 B|
|reader snapshot枠|2|なし|
|mount読取り上限|1,056,768 B|同じ|
|通常の1 byte read要求量|12,288 B|同じ|

増分6,264 Bは旧disk rootとreader root・管理情報の保持による。
状態には既存4 KiB scratchを含むが、call stack・backend・OS file cacheを含まない。
store自身はheapを確保しない。1 GiB型と16 GiB型の状態サイズは同じで、default状態は16 KiB以内に収まる。
2 MiBのstore envelopeとnative memory profileは変更しておらず、実機の総RAM peakは未測定。
mountは両rootが参照するleafだけを読み、free pageの内容やpayloadは走査しない。

## 検証

[追加Zig test 6件](../../src/storage/index_gc_test.zig)で次を確認した。

- 3ページpoolでput／removeを6,000回実行し、payloadを増やさず世代6,001を再mount。
- 2つのreaderが異なる旧世代を読み続けられること、pin解放・slot再利用後のstale handle拒否。
- 空き0でのroot-only回収、pinによるNoSpace、解放後の再利用、admission時の書込みなし。
- rollbackしたleafだけの再利用、fault後のpin解放。
- 未公開の書込みが媒体へ到達しても旧rootのleafを壊さず、別途current rootを破損させた場合に旧世代へfallback。
- root退役と回収済みleafへの書込みを連続させた84 event、3種の背景writeback、2種のflush順、6種のsector prefix。

最後のcampaignは3,024条件の中断を検査した。正常終了6件は世代5を回復し、途中の中断は最後にackした世代（3または4）以上の完全な状態を回復した。
回収のack後に後続writeが中断した場合は、世代3への巻戻りも許容せず、世代4以上を要求する。
これは選んだ故障モデル内の結果で、媒体の実電源断耐性の証明ではない。

[negative control](../../tools/index_gc_negative_control.py)は、copyしたsourceで保護を一つずつ外す。
readerの保護を外すと世代5で旧snapshotのreadが`Corrupt`となり、旧disk rootの保護を外すとfallbackが`Corrupt`となった。
元の公開前syncを外すnegative controlも、公開dataの破損を引き続き検出した。

16 GiB疎file試験は8ケース・20 process。
全128 leafを使う256ページpoolで、readerが世代5を保持したまま世代6へ更新した。
回収後もpinによって空き0になり、writerが書込み前に止まることを確認した。
pinを解放すると128ページが空き、その後も全leafの更新と回収を4回繰り返して、計640 leaf更新を行った。
別processで世代15と空き128ページ、変更していないpayloadを照合した。
metadata／payloadの保存rangeから別の疎fileを再構築した場合も同じ検査に通った。

Zig Debug／ReleaseSafe各221件、Python 168件、format／ZLint／ShellCheck、RV32のbroker・checkpoint compile、
6種類の既存native ELF link／配置監査が合格した。
既存のcheckpoint中断5,832条件と初期COW中断4,212条件も両build modeで通っている。
nativeの起動経路や保持済みcold-Flash候補は変更していない。

## 再現と次のgate

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
sh tools/run-checkpoint-test.sh
python3 tools/index_gc_negative_control.py .tools/zig-0.17.0/zig
python3 tools/checkpoint_negative_control.py .tools/zig-0.17.0/zig
sh tools/run-static-analysis.sh
```

[構造化結果](2026-10-27-store-index-gc.json)と
[source・binary・range・失敗比較・ログのarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-index-gc-host)を保存した。
manifestを除く42 fileのSHA-256と、保持中のcold-Flash候補55 fileのhashを再照合した。
次はpayloadの回収・連続領域の確保とclean reserve、その中断試験。
streaming／部分書込み、bounded tail replay、実SD／NORへの接続、SQLite PERSIST/FULLとWALも未実装のまま。
