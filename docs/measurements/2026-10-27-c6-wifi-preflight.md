# C6 AP接続・IPv4取得プローブの準備

2026-10-27。**AP接続・DHCPによる実機IP取得は未達**。試験用コードとP4イメージの
確認まで。既存のP4/C6 firmware、OTA選択、SD内容はこの作業では書き換えていない。

## 追加した経路

native P4 → SDIO → C6 ESP-ATの順に、既存AT初期交渉に続けて以下を実行する。

```text
AT+CWDHCP=1,1
AT+CWDHCP?
AT+CWJAP                     # またはエスケープ済みSSID/passwordを指定
AT+CWSTATE?
AT+CIPSTA?
```

DHCPのstation bit、CWSTATE=2、IPv4/gateway/netmaskの全フィールド、各コマンドの
終端OKが必要。古いIPフィールド、0.0.0.0、loopback/multicast/link-local、
異なるsubnetのgateway、不正mask、切断を合格にしない。DHCPパケット自体の
観測、DNS、TCP、Internet接続はこの判定の対象外。

資格情報は権限0600のローカルJSONから生成し、Wi-Fi用の成果物を
ignoredの`build/c6-wifi-probe/`へ分離する。イメージ自体に資格情報を含み得るため
配布しない。現在ビルドした候補は`saved:true`で、資格情報は含まない。
これはESP-ATの保存設定用であり、既存ESP-HostedのNVSからの移行確認ではない。

## 実行した確認

- Debug / ReleaseSafe: 各144/144ホスト試験通過。
- 新しい4試験でAT全シーケンス、正常lease、切断による無効化、DHCP無効、
  未接続、欠落・重複・不正IP、最後のERRORを確認。合成応答であり無線の証拠ではない。
- 静的解析、RV32でのWi-Fi経路codegen、既存native ELF 6種類の監査、
  image checker 5試験を通過。
- saved設定のP4 Wi-Fiイメージをビルドし、SRAM/ROM・RTOS未リンク・FP未使用を監査。
  bin: 65,616 bytes、SHA-256
  `45d31d5c173c55391a2de45c55dcab851ee86217a9fdb3f845eeb7f03080307a`。
  ELF: `8b4569ac9860ef15cbdd468ec0eb408ab025a9b3281a528fe67f536f7f2e8d98`。
  SRAM予約81,600 bytes、未使用heap領域49,472 bytes。
  `build/c6-wifi-probe/receipt.json`と`image-audit.json`に入力source/artifact hash。

## 実機で確認できたことと残る条件

USB列挙では`/dev/cu.usbmodem101`のEspressif USB JTAG/serialポートが一つだけ。
排他openは当初別作業のPythonにより拒否された。そのプロセスが終了した間に、
DTR/RTSをassertせず、書き込み0 bytesの受動受信を実施し、P4側の
`NIHOS_NATIVE_BOOT backend=zig-sram rtos=none`を確認した。その後も別の実機試験が
同ポートを使用しており、割り込まなかった。これはC6 firmwareの識別ではない。
ローカルの受信記録は`build/wifi-device/passive-console.log`（0600）。

C6の専用download接続、実際のC6 chip/flash、既存image/NVSのbackup・readbackは
まだ確認できていない。[M5Stack公式手順](https://docs.m5stack.com/en/guide/tab5/c6_wifi_restore)
では、基板上のC6専用端子へUSB–TTL変換器を接続する。P4のUSBからC6を書き換えられる
とは仮定しない。接続先APと資格情報も未確認。

次の実機工程はC6ポートの識別とbackup → matching AT firmware → P4既存layout/OTAを
保存した試験イメージ起動 → `NIHOS_C6_WIFI_PASS ip=...`取得。C6は工場状態では
ESP-Hostedのため、ATプローブだけをP4へ書き込んでも通信できない。

## 内蔵接続と更新経路の再確認

上記は**ESP-ATへ置換する試験**の準備であり、通常のWi-Fi利用に外部UARTが
必要という意味ではない。ユーザーの指摘を受けて修正する。
[Tab5公式pinmap](https://docs.m5stack.com/en/core/Tab5)はP4–C6間のSDIOと
reset配線を示す。MeOSの現行`drivers/wifi/wifi_tab5.c`も、既存C6のESP-Hostedに
SDIO/RPCで指示し、DHCPをP4で処理している。コードは参照のみでコピーしていない。

[Espressifのtransport OTA例](https://github.com/espressif/esp-hosted-mcu/blob/v2.13.1/examples/host_performs_slave_ota/README.md)
では、既存SDIO/SPI/UART transportを使い、追加配線なしでslaveを更新する。
同tag `common/proto/esp_hosted_rpc.proto`にはOTABegin/Write/EndのRPCがある。
これは搭載C6がそのRPCを実装している証拠ではないので、まずversionと既存protocolを
内部SDIO経由で確認する。OTA Begin自体が消去を始めるため、対応調査目的で送らない。

ローカルにあるM5Stack公式UserDemoの参照C6イメージ
`ESP32C6-WiFi-SDIO-Interface-V1.4.1-96bea3a_0x0.bin`のpartition tableを
ESP-IDF v5.4.4のparserで調べた。**実機からのreadbackではない**。
参照image SHA-256:
`1173bf86ab86c8dbd3f9863d10b15c2e46f57000b2b77c803e2b79bd0a3fa38e`。

```text
nvs       0x009000  16 KiB
otadata   0x00d000   8 KiB
phy_init  0x00f000   4 KiB
ota_0     0x010000   1536 KiB
ota_1     0x190000   1536 KiB
```

現在のESP-AT appは1,691,616 bytesで、この参照OTA slot（1,572,864 bytes）より
118,752 bytes大きい。AT独自のNVS/partition構成も異なる。現在の候補をそのまま
内部OTAへ流すことはできない。OTA移行には既存layout/NVSに適合する小型候補と
復旧設計が必要。通常のAP接続試験をその移行完了待ちにする理由はない。

実機工程を「既存C6を書き換えずにnative SDIO/Hosted識別・version query」へ戻す。
AP/IPをfactory Hostedで確認する場合、P4 DHCPの証拠として記録し、最終目標の
C6 TCP/IPオフロードとは区別する。最後のUSB再列挙ではEspressifポートが消え、
Bluetooth/debug-consoleの2ポートのみとなった。この時点では実機操作を追加していない。
