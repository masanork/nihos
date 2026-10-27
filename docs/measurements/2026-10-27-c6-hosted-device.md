# 内蔵C6の実機SDIO/RPC接続とAP接続試行

2026-10-27、Tab5実機。**内蔵C6のHosted制御・AP接続・DHCPでのIPv4取得を通過**。
初回は保存APがreason 201 (`WIFI_REASON_NO_AP_FOUND`)で見つからなかったが、
ユーザー指定のローカル設定を使った追試で成功した。DHCPはP4側で実行しており、
C6 TCP/IPオフロードや通常OSのネットワークサービス統合の実証ではない。

## 対象・書き込み範囲

- `/dev/cu.usbmodem101`、P4 rev1.3、40 MHz crystal、16 MiB flashを再確認。
- 実機partition tableは `nvs 0x9000/24 KiB`、`phy_init 0xf000/4 KiB`、
  `factory 0x10000/1 MiB`。OTA partitionはない。
- ユーザーが開発環境から再現できるためbackup不要と指示。全flash readを中止した。
  完了した全flash backupはない。書込先識別用のpartition table 4 KiBのみ読み出した。
- P4のfactory appへ65,616-byte試験imageを書き込み、esptoolのhash照合を通過。
  bootloader、partition table、P4 NVS、microSDは書き換えていない。
  C6 firmwareの書き換えは一度も行っていない。

現在のP4 imageは下記候補の専用boot fixtureで、結果出力後haltしている。
通常OSへの組み込みや元の開発imageへの復元はこの試行に含めていない。

## 実機で見つかった不具合と修正

初回のnative実行はSDIO enumeration/function enable/4-bit切替まで通過した後、
scratch-7 datapath doorbellのCMD52 writeで停止した。R5は`0x1000`でerror bitなし、
readback byteは0だった。従来の`writeByte`は書込値1との一致を要求していた。

doorbellでは安定したbyte値のreadbackを要求せず、R5のerror検証を維持したうえで、
C6からのINITを応答として待つよう修正した。`writeDoorbell`を追加し、通常の
configuration byteに対する厳密な`writeByte`は変更していない。
回帰試験はself-clearing registerとIO current-state bitを模擬し、R5 error時には
引き続きcontrollerがretireすることを確認した。

USB resetの初期試行ではP4がdownload modeへ戻った。最終的には同じ排他serial
descriptorでesptool write/verify、DTR解除、USB向けRTS reset、console受信を実行し、
`SPI_FAST_FLASH_BOOT`とnative fixtureの起動を確認した。

## 保存APでの初回実測結果

修正後の2候補で同じ地点まで到達した。最終候補の新規boot結果:

| 項目 | 値 |
| --- | --- |
| Native backend | Zig SRAM、RTOSなし、CPU1 parked |
| SDIO | Slot 1、4-bit、設定400 kHz |
| C6 INIT chip ID | 13 (ESP32-C6) |
| C6 version RPC | ESP-Hosted 1.4.1 |
| Hosted frames | 13 |
| TX / RX | 361 / 504 bytes |
| 最後のRPC | 538 (`Resp_WifiConnect`)、status 0 |
| 切断event | reason 201 (`WIFI_REASON_NO_AP_FOUND`) |
| 接続event / DHCP Offer / IP | なし |
| Probe結果 | status 0、stage 11、`NIHOS_C6_HOSTED_WIFI_FAIL` |

Wi-Fi init、RAM storage指定、STA mode、start、power-save無効化、MAC取得、connect
要求のRPCが実機で応答した。APを認識したことやDHCP serverとの通信を示す結果ではない。
reason名はpinned SDKの`esp_wifi_types_generic.h`で照合した。

旧C6はmode tagを返さず`peer_mode=255`。全13 frameのHosted checksumは0で、
uncheckedとして計数している。SDIO/DMAでの読み出しとprotobuf ID/UID照合は通ったが、
この初回時点では大きなEthernet frame、DHCP、cold power-cycle、負荷・同時動作は未検証。

## 候補と証拠

最終candidate:

- bin SHA-256: `5cf45cbb755c587ae007a4378bddb7540fe0fba2024c639eb59f78dd84959f3d`
- ELF SHA-256: `9470444c5a1c998665f8c4fbc7e86bd3526be76f3314ae5b9c8bfc120d858b7e`
- Debug / ReleaseSafe: 各153/153。静的解析とnative image監査を通過。

private/ignoredの`build/wifi-device/physical-01/`にログを保存。

| ログ | 対象と結果 | SHA-256 |
| --- | --- | --- |
| `run-04.log` | 初候補、doorbell readbackで停止 | `a26eae659be51407d0f20ba100aabea4a9f69a975a6aca4b0efe2122a4763651` |
| `run-06.log` | 修正候補 `5890f73c…`、Hosted 1.4.1、reason 201 | `67a657efe506d148a92f5c151aae0e6669c3dc013cc14b37064afcfc7746ebd9` |
| `run-07.log` | 最終候補 `5cf45cbb…`、Hosted 1.4.1、reason 201 | `d05e2b85a35b3be2d862c19796e6af7bb1dff6889bb50642ba23c36be2546947` |

`attempt-06.json`、`attempt-07.json`に候補hash・時刻・実行時間・結果、
`write-06.log`、`write-07.log`に書き込み/照合結果がある。
この時点ではAP設定待ちだった。以下の追試で設定指定とDHCP取得まで進んだ。

## 明示AP設定による成功

ユーザー指定の`/private/tmp/wifi.json`を使用。SSID値の先頭引用符が一つ欠けていたため、
原文を表示せず、private/ignoredの`provided-wifi.json`でその構文だけ補正した。
元ファイルの内容は変更せず、権限を0600にした。SSID/passwordはgitやconsoleへ出していない。
AP設定はC6のRAM storageに指定し、C6 firmwareは既存1.4.1のまま。

| 項目 | 実機結果 |
| --- | --- |
| IP | `10.193.127.151` |
| Gateway / DHCP server | `10.193.127.155` |
| Netmask | `255.255.255.0` |
| Lease | 3599秒 |
| 接続event | 1 |
| Hosted frames | 17 |
| TX / RX | 1163 / 1292 bytes |
| Probe | status 1 / stage 12 / error 0 / cleanup failure 0 |
| network drop / disconnect reason | 0 / 0 |
| Capture所要時間 | 約5.34秒（書き込み時間を含まない） |

```text
NIHOS_C6_HOSTED_WIFI_PASS ip=10.193.127.151 gateway=10.193.127.155 netmask=255.255.255.0
```

同一bootのreportとPASS行を照合し、INIT識別、接続event、Wi-Fi RPC成功、
Offerと取得IPの一致、正のlease時間、gateway/subnet、trap/FAIL不在を確認した。
`ip-result.json`に検証結果を保存した。DHCP ACKは公開されたsourceのparser経路で
判定している。独立した無線packet captureは行っていない。

成功候補は65,616 bytes。生成moduleとimageは資格情報を含むためprivate/ignoredのまま。

- bin: `684beb1a9b2cf76cf82ac5b95eb60479893ec50af3475e3f4ef5064510d8ec7d`
- ELF: `99f554616bd8dc3735c3e2d2139fe5f7d560f9c91220fd5d77f332e400dc8cfc`
- `run-08.log`: `7a5d8e1c24502925c28e243885c9d976da7f613f0c4f0aa56a09b75ba64d0048`
- `attempt-08.json`、`write-08.log`に候補hashと書き込み/照合結果。

成功候補の19 source hashと成果物hashがreceiptに一致し、書き込んだ候補hashと
実行metadataも一致することを確認した。source変更はなく、入力AP設定のみを変えた。
これは1回の取得成功で、lease更新、ARP conflict検出、DNS/TCP/Internet疎通、
cold power-cycle、連続運転や通常OS統合は未確認。現在P4は結果を出してhaltする専用fixture。
