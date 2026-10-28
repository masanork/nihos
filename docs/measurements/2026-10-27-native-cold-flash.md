# Native検証コードのFlash配置とSRAM余裕

2026-10-27。`codex/tab5-memory-broker`、実装commit `0195804`。
通常contextで実行する検証用11関数をmapped Flashへ移し、resident SRAMに10,368 Bの余裕を戻した。
同じソースの設定OFF／ONをビルドして比較し、配置監査とホスト試験に合格した。
このimageの実機起動・実行時間・stack計測は未実施。Tab5を再接続してから確認する。

## 配置変更と予算

|項目|設定OFF|設定ON|
|---|---:|---:|
|低位resident|114,688 B（112 KiB）|104,320 B（101.875 KiB）|
|112 KiB枠内の余裕|0 B|10,368 B（10.125 KiB）|
|旧boot heap|49,152 B|59,520 B|
|broker内部payload|212,992 B|212,992 B|
|broker外部payload|31,457,280 B|31,457,280 B|
|broker metadata|12,912 B|12,912 B|

Flashへ移した関数の合計は10,382 B。alignmentを含むresidentの回復量は10,368 Bとなった。
stack予約と高位SRAM予約、brokerの登録範囲・quota・最低空きは一致する。
戻した領域は112 KiBのresident予算内の余裕であり、アプリの貸出し上限へ自動的に加算しない。
このopt-in配置候補の監査では、residentを104 KiB以下として8 KiB以上の余裕を要求する。

新しい`NIHOS_NATIVE_COLD_FLASH=1`で有効にする。既定値は無効で、deviceのbroker version 2が必要となる。
起動時からのbroker全面置換や16 task化は含まない。

## Flashへ移す関数とresidentへ残す処理

旧heapのobject／slab／pool検証と終了時検査を6関数、高位SRAMの初期化・VM検証・CPU間交換・終了時検査を4関数、
SQLiteの起動試験を1関数移した。いずれも通常のbootstrap／task contextから実行する。
SQLのmapped span内に専用の範囲を設け、[配置policy](../../tools/native-cold-policy.json)で全11関数を列挙する。
関数名のprefixだけで許可する例外は追加していない。

起動・IRQ入口、scheduler、allocator APIとcleanupの13関数は低位residentへ残す。
既存のbroker IRQ hook、SD controller callback、DMA staging／descriptorのresident監査も維持する。
PSRAM mappingやcache停止を扱う処理は移動対象にしていない。

監査は専用範囲内の11関数の一致・重複・混入・重なり・空隙、critical関数のresident配置、予算余裕を確認する。
manifestにはsourceとpolicyのSHA-256を保存する。
これは関数配置の検査で、IRQ／cache停止中の全推移call graphを証明するものではない。

## ホスト検証と候補

Zig Debug／ReleaseSafe各184件、Python 168件、format／ZLint／ShellCheck、RV32 broker compile、
既存6種類のnative ELF linkと配置監査に合格した。追加したPython 10件は、不正flag、manifest欠落、関数混入・欠落・重複、
critical関数のFlash／PSRAM／heapへの移動、予算余裕不足、不正なprofileやsource metadataを拒否する。
同じソースのbroker構成を設定OFF／ONでlinkし、登録payload・stack・高位予約の一致を照合した。

候補appは814,400 B、SHA-256 `bf0445458396564e18b3b1c8a57e1b24780becb05804e3569432bbf24a4a3044`。
ELF SHA-256 `f30d42ffecd5e52f6d995469e36442c133487f527dca6606370b38662ae7d5e0`。
保持済みloader ELF／cache設定を指定した配置監査にも合格した。

```sh
NIHOS_NATIVE_COLD_FLASH=1 \
NIHOS_NATIVE_MEMORY_BROKER=1 NIHOS_NATIVE_HIGH_SRAM=1 \
NIHOS_NATIVE_SDMMC=1 NIHOS_NATIVE_SDMMC_PROFILE=2 \
NIHOS_NATIVE_STORAGE=1 NIHOS_NATIVE_STORAGE_SERVICE=1 \
sh tools/build-native.sh device sqlite
```

[構造化結果](2026-10-27-native-cold-flash.json)に比較、関数位置、候補hashと未実施gateを保存した。
[固定候補のarchive](/Users/masanork/Documents/Codex/2026-10-27/nihos-native-cold-flash-host-candidate)には候補、比較用ELF、
変更source、loader、SDK参照image、ホストログ、実機試験runnerを保存し、55ファイルのSHA-256を再照合した。

## 再接続後の実機試験

保存したrunnerは、全artifactのhashと対象Tab5を確認し、新しい出力directoryで試験する。
同じexclusive serial FDを保持したまま、partition tableの事前照合、SDK参照の再取得、loader／app書込み、
3回のUSBリセット起動と各PASS後10秒の監視、SD／file API比較、最終Flash照合を行う。
対象は従来と同じP4 rev1.3、MAC `e8:f6:0a:e2:e8:9c`。partition tableは照合だけで変更しない。

実行時にportを再発見し、他の利用者がいないことを確認する。例えばportが従来どおりであれば次を実行する。
出力directoryは存在しない新しい名前を使う。

```sh
/Users/masanork/.espressif/python_env/idf5.4_py3.9_env/bin/python \
  /Users/masanork/Documents/Codex/2026-10-27/nihos-native-cold-flash-host-candidate/run.py \
  --port /dev/cu.usbmodem101 --output build/cold-flash/physical-1
```

runnerは構文と`--help`だけを確認済みで、この候補を実機へ書き込んではいない。
この回ではUSB操作を行わず、前回の[実SD lifetime試験](2026-10-27-broker-sd-lifetime.md)と今回のホスト結果を区別する。
