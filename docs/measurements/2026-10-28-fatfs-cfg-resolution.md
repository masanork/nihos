# nonreturning callとjump tableのCFG確認

2026-10-28。base `e1fc178`。前回残った未提供frameを通常復帰不能なcalleeのCFGから確認し、
5箇所のjump tableを関数内分岐として確認した。[結果JSON](2026-10-28-fatfs-cfg-resolution.json)へ根拠を保存した。
この記録は静的・host試験の結果であり、実機のtask実行や総stack合格ではない。

## 関数名に依存しない通常復帰不能の確認

`main.fail`の到達可能なCFGには通常return、未知のtail exit、末尾からのfallthroughがなく、
loopへ収束することを確認した。callは通常のABIに従うという仮定を残す。
そのbinary summaryとcode hashを依存関係として、`nih_native_task_failed`の末尾callを解析した。
残っていたローカルSP減少量は16 Bで、metadata未提供13関数を全て解析できた。

宣言の`noreturn`や関数名は根拠にしない。同じsymbolのbodyをreturnへ改変した実ELFでは、
callerの解析が未完了になるnegative controlを保存した。
trapや未確認tailを、通常復帰不能なcalleeと見なさないこともhost testで確認した。

## 5つのjump table

限定したcompiler形のみを認識する。直前の`li bound`とunsigned `bltu bound,index,default`、
単一入口のdispatch block、indexを上限内へ制限した全値、読取り専用allocated PROGBITSの全table wordを検査する。
absolute / base-relativeの両形式について、全targetが同じfunctionのinstruction boundaryへ戻り、
dispatch途中や別functionへ入らないことを確認する。
他の未知transferやrange guardを迂回するbranchがある場合は、未解決のまま残す。

到達可能なVFS close/openAt、Backend.open、ff_wtoupper、backend resultの5箇所を確認した。
table / function / dispatchのhashと全targetを結果へ保存した。
実ELFのtableを関数外targetへ改変する5例、unsigned guardをsignedへ変える5例も全て拒否した。
これはdispatchの制御範囲を確認したもので、tableの各caseの機能やcalleeのstack消費を証明していない。

## 残る境界

入口の未提供frameは0、未解決transferを含むfunctionは9→4になった。
残りは`tick`のcancel callback、`disk_read`のsector callback、`ecall`のkernel境界、ROM putcである。
fixture sector callbackは候補edgeとしてcostに含めるが、targetの排他性を証明した扱いにはしない。
既知frame / ローカルSP減少の構造上の合算は入口3,088 B、FSD3,072 B、client288 B。
通常処理SP予算3,952 Bとの比較だけで全stackを合格にせず、`--require-closed`は引き続きexit 1になる。

runtime source、ELF/image bytesは前回candidateのまま。今回の変更はhostの解析と採取runnerである。
Python230件、format / ZLint / ShellCheck、既存6 native ELF監査を確認する。
CIにも限定jump-table解析を設定した。remote CI実行や新たな実機結果はこの記録に含めない。

## 実機採取runnerの専有・後処理

pyserialのadvisory lockに加えてTIOCEXCLを要求し、flockへ参加しないraw openerが
cu / tty両aliasでEBUSYになることを検査してからdevice commandへ進む。
private PTYではこのhostのioctl成功だけで排他成立しないケースを観測したため、成功returnだけを信用しない。
両aliasの成立を確認できなければrunnerはdevice commandへ進まない。
claimはDTR/RTS変更より前に行い、取得前から開いていた別PIDも確認する。

採取前のlayout不一致等でも、identityが確認できたdeviceだけをresetしてportを解放する。
書込み後の復元が未完了なら、未確認imageを起動しない。complete recordは正常な後処理とFD解放の後に保存する。
private PTYとmockで検査しており、実機portでの成立やFlash復元は、別の実機記録で確認する必要がある。

```sh
python3 tools/check-native-call-stack.py build/native-fatfs-stack/nihos-native.elf \
  build/fatfs-flow-close/analysis.json --objdump riscv32-esp-elf-objdump \
  --derive-frames --candidate-edge disk_read:nih_fatfs_fixture_read --resolve-jump-tables
```

実taskのpaint/guard、停止/wakeup、実カードFatFs、clean POR、永続SQLite、書込み・電断耐性は残るgateである。
