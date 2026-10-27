# ホストfile backendとプロセス再起動

2026-10-27。`codex/store-crash-model`、実装commit `7503341`。
[COW公開モデル](2026-10-27-store-crash-model.md)へホストの実ファイルを接続し、6ケースの別process試験を通した。
同期成功後のcommitは、processをSIGKILLしてから別processで開いても新世代を回復した。
これはmacOS arm64上のfile I/Oとprocess寿命の検査で、OSや物理媒体の電源断試験ではない。

## backendの契約

[file_media.zig](../../src/storage/file_media.zig)は、既存の通常fileをread/writeで開く。
容量の完全一致を確認し、非待機のadvisory exclusive lockを保持する。末尾のsymlinkを辿らず、作成・切詰め・初期化を自動で行わない。
imageの作成と、その名前を含む親directoryのsyncは呼出し側の責任とする。

readはpositional I/Oで要求長を満たし、短いreadをI/O faultとして扱う。
writeは短いwriteの残りを継続し、進捗0を拒否する。syncは`std.Io.File.sync`を実行し、成功後だけ完了数を増やす。
read／write／syncのI/O fault後は、そのinstanceでの再利用を拒否してclose／reopenを要求する。
協調するwriter間のlockであり、非協調processの変更や公開capability ABIまで保護するものではない。

backendは媒体全体のcacheやsector mapを持たず、48 KiB型と16 GiB型のdescriptorサイズが同じことを検査した。
実際のprocess試験は512 KiB image・最大8 objectのモデルを使う。16 GB媒体のmap／mount性能を検証したわけではない。
4 KiBの公開モデル形式は実験用のままで、SD／NORの最終log形式にはしていない。

## 別process試験

[runner](../../tools/store_file_probe.py)が新しいimageをexclusive createし、内容を埋め、fileと親directoryのfsync成功後にprobeを起動する。
71,681 Bのobjectと追加objectを使い、読取り側は全byteと削除されたobjectの不在を確認する。
終了を待つprobeはstdoutへ状態をflushしてからstdinで待機し、runnerが自分で起動したprocessだけをSIGKILLする。

|ケース|確認した結果|
|---|---|
|通常commitと別processからの再open|世代3を回復し、全payloadを照合|
|root公開前のSIGKILL|未公開payloadを露出せず、世代2を回復|
|同期成功のack後にSIGKILL|close処理を通らず、世代3を回復|
|writer競合とowner終了|競合はWouldBlock、owner終了後は再open可能|
|fileを変更しないopen拒否|容量不一致・不存在・symlinkを拒否し、作成や切詰めをしない|
|両rootが破損|Corruptを返し、file bytesを変更せず、formatしない|

計22 processを起動し、うち3 processをSIGKILLした。全6ケースに合格した。
ここでのSIGKILLはOS cacheを失わせない。未同期dataを捨てる4,212条件の試験は、別のmemory-backed故障モデルで引き続き実行する。

## I/Oエラーとackの境界

追加したZig 5件は、close／reopen、排他的所有、短いread、境界外access、17 Bずつのwrite、進捗0、write／syncエラーを検査する。
I/O vtableを差し替えたエラー注入では、実際のfile I/Oへ転送しつつ、指定したsyncだけを失敗させる。

root書込み後のsyncを失敗させた場合、新世代をackせず、storeとbackendをfault状態にした。
rootがすでにOSから見えている可能性があるため、reopen後は旧／新の完全な世代だけを許容する。
I/Oエラーを「必ずrollback済み」とは扱わない。

## 検証と再現

Zig Debug／ReleaseSafe各202件、Python 168件、format／ZLint／ShellCheck、RV32 broker compile、
既存6種類のnative ELF linkと配置監査が合格した。別process試験もすべて合格した。
native起動経路へは接続しておらず、実機待ちのFlash配置候補は変更していない。

```sh
.tools/zig-0.17.0/zig test src/root.zig
.tools/zig-0.17.0/zig test src/root.zig -O safe
sh tools/run-store-file-test.sh
sh tools/run-static-analysis.sh
```

process試験は毎回`build/store-file/process.XXXXXX`へimage・固定probe binary・結果を保存する。
既存の出力directoryは上書きしない。runnerの検査はPythonの最適化で無効になるassertに依存しない。

[構造化結果](2026-10-27-store-file-backend.json)と
[source・binary・image・ログのarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-store-file-backend-host)を保存した。
24通常fileのSHA-256と1 symlinkの参照先を再照合した。

## 次のgate

実fileのfsync成功とprocess再起動は確認したが、OS再起動、実電源断、カードのflush／除去／故障は未検証。
実SD／NORへの書込みや、GC・reader pin・永続index・checkpoint／bounded tail replayは追加していない。
次は、媒体容量に比例するRAM mapを使わずに、indexと回復量を制限する段階へ進む。
SQLiteの永続VFSは、その上で部分I/Oとjournalのsyncを検証してから`PERSIST`／FULLで接続する。
