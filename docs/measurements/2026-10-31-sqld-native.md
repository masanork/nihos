# sqldの通常起動・microSD永続化

2026-10-31。最終実機source: `e75f1f17a4a7bcc200657aff11e924a19436f347`。
[証拠一覧](evidence/2026-10-31-sqld-native/index.json)、[結果](evidence/2026-10-31-sqld-native/result.json)。

## 結果

Tab5 / ESP32-P4 rev1.3の通常起動でsqld ownerが常駐し、xyのScheme providerから利用できた。
最終候補は公開既定build（`xy_trace=false`, `sqld=true`, provision CID=0）。
SQLの値を条件に日本語ファイルを読み込み、`normal-proof.scm`へ保存する単一Scheme式で
copied RPCを11件完了した。保存後の再起動でgeneration
39 → 40を回復した。
Flash全16 MiBの書込み前後照合と、最後の照合後の常駐logを保持した。
image SHA-256: `2ca9ca6276226b8b5ccc85d37f3c32efe7fe249586d3039a0b168e7dba489ef5`。

別のtrace候補では29式を実行し、SQL更新とrollback、filesystem rollback、
snapshot/restore/release、GC、space、checksum、SQL integrity、日本語本文のsave/loadを確認した。
再起動後にSQL `before` と本文 `日本語 source` を直接読み戻した。
trace候補と最終既定候補のsource/image identityは各receiptで区別している。
表示DMA・両CPUのtick・C6/BLEの進行をlogで確認した。panelの画素を実撮影で比較した記録ではない。

## 実装と予算

- CPU0にSQLite専用task。SD実I/Oは既存CPU0 storage ownerへコピーしてpark/wakeupする。
- 一般heapから2 MiBを予約し、store/service/transport、1 MiB memsys5、512 KiB write-through read cache、
  SQLとScheme各64 KiB stackを配置した。2 MiBは予約量であり、全量がlive payloadではない。
- 最終primary SRAM heapは51,136 B。49,152 B floorを維持した。
  操作完了時のSQLite使用量は209,856 B、owner stackの観測high-waterは9,008 B。
  SQLiteの瞬間peakを測定した値ではない。
- MBR marker `NIHSQLD1`、type `0xda`、LBA 2048から8192 sector（4 MiB）。FATはread-onlyのまま、
  grant後のraw writeをこの範囲に限定する。MBRの書込みはCID指定の初期化候補だけに許す。
- 許可された試験用microSDにpartition mapとrootを初期化した。全カードのsecure eraseではない。
  最後は自動初期化を無効にした既定imageへ入れ替えた。
- SQLiteはPERSIST rollback journal + FULL。WAL実装の認定ではない。
  明示SQL transaction leaseはhost 2秒、native 30秒。SQLite自身の自動rollback後も次の要求を受け付ける。
- I/O待機中に入力を遅延し、Escの間隔を保持する。結果の画面revisionはcompletion後に更新する。

## 確認

- Python 565 tests成功。実SQLite/checkpointの51個のwrite/sync位置に対する102 crash casesを含む。
- Zig ReleaseSafeの全73 build steps成功。詳細は保存したsummary（cached stepsを含む）。
- ZLint: 344 files、0 errors / 0 warnings。
- 実normal FSのhost MMIOモデル50 cases + 3 negative controls。
  sqld block capabilityではcaller・region・MBR・コピー後の元buffer変更を検査した。
- default ELF/image監査とlinked identityの5 negative controls。
- sqld/SQLite/store/native ownerのRV32 object compile。
- Native graphics emulator smokeでreference pixels・preemption・heap回収を確認した。
  sqld無効profileのheap floorも維持する。これはSD物理試験とは別の証拠。

## 再現

```sh
sh tools/build-native.sh device integer
# output: build/native-device-network-devices-camera-sqld/
```

Homeで`n`、EscでSchemeへ入り、次を利用する。

```scheme
(buffer/save! "draft.scm")
(buffer/load! "draft.scm")
(sql/check)
```

既知markerのない媒体を通常buildで初期化しない。試験初期化は実カードCIDのCRC32に一致する
`NIHOS_NATIVE_SQLD_PROVISION_CID`で限定し、終了後は0へ戻す。CRC32は暗号学的なカード認証ではない。
APIの全体は[契約](../planning/sqld-xy-service.md)を参照。

## 残る認定

物理電断、clean OFF/ON、抜去後の無停止再接続、満杯・実媒体I/O故障・取消の全経路は未認定。
snapshot tokenはmount内だけ有効。SQL壁時計は未公開。
Flash全体のbackup・compiled images・private configurationはprivateに保持し、repositoryへ入れていない。
