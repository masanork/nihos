# 既存C6向けnative Hosted station / DHCP試験

2026-10-27。C6をESP-ATへ置換せず、内蔵SDIOから既存ESP-Hostedを利用する
P4 native試験を追加した。**ビルド・ホスト試験までで、実機AP接続・IP取得は未達。**
本ターンのUSB再列挙ではEspressifポートはなく、Bluetooth/debug-consoleのみ。
P4/C6のflash、OTA metadata、SDへの書き込みは実施していない。

## 実装

- `src/net/hosted.zig`: 12-byte Hosted frame、checksum、protobuf/TLVを容量制限付きで
  decode/encode。fragment・長さ不整合は失敗。UIDとRPC IDを照合する。
- `src/net/hosted_station.zig`: C6 INIT識別、version query、Wi-Fi初期化、RAM保存設定、
  STA/start/power-save/MAC/config/connect、接続通知、DHCPの単一owner。
  C6のOTA・設定永続化RPCは呼ばない。SSID/passwordをログに出さない。
- `src/net/dhcp.zig`: P4側のDiscover→Offer→Request→ACK。xid/MAC/server、IP/UDP長、
  IPv4 checksumと非zero UDP checksum、IPv4/mask/gateway/lease秒数を検証。
  DHCP NAK・切断で失敗し、未完了ACKやOfferだけで成功しない。
- native adapter: C6電源をI2C expander 0x44 P0だけread/modify/writeし、他bitを保存。
  expander resetやcharger設定変更を行わず、C6 reset、400 kHz SDIO、scratch-7で
  datapathを開く。512-byte transfer、Hosted側1536-byte RX bufferにつき1 TX packet、
  64 credit上限。IRQ・heap・CPU1・microSD共有動作は使わない。
- `NIHOS_C6_PROTOCOL=hosted sh tools/build-c6-sdio-probe.sh`。
  任意の0600 JSONを`NIHOS_C6_WIFI_CONFIG`で指定。指定なしはC6の保存済みAPを使う。
  成果物はprivate/ignoredの`build/c6-hosted-probe/`。

このモードのDHCPはP4で動くため、C6 TCP/IPオフロードの実証ではない。
最終的なオフロード方針は保持し、まず既存ファームとの無線経路を成立させる。
AT用の既存プローブも別モードとして残す。

## 参照した一次資料

実装は新規Zigで、MeOSのdriverソースは取り込んでいない。通信フィールドは
[Espressif ESP-Hosted-MCU v2.13.1](https://github.com/espressif/esp-hosted-mcu/tree/v2.13.1)
の公開定義を参照した。このtagを搭載C6の版と仮定してはいない。

| 定義 | SHA-256 |
| --- | --- |
| `common/esp_hosted_header.h` | `0b1c053e0f1f1008fc94b5558fd85a2bc7c0f6b44a8eebe81a78a035f6a36cfe` |
| `common/transport/esp_hosted_transport.h` | `9223cb084049750586fd9e184361f3d66a407e5e85c608f97f755b7fd206e63a` |
| `common/transport/esp_hosted_transport_init.h` | `e50edb32e2df1cc348680af671bda5065b6abd01fa285aa72e2a2d69679948ac` |
| `common/proto/esp_hosted_rpc.proto` | `8b00a7fa1158b0f8ecb9a26b3b71b237c98e7c2837afb36bb4299e79a85db843` |

DHCP wire定義は[RFC 2131](https://www.rfc-editor.org/rfc/rfc2131)と
[RFC 2132](https://www.rfc-editor.org/rfc/rfc2132)。限定boot clientであり、更新・再束縛、
option overload、ARP conflict detectionを含む完全なDHCP実装ではない。

## 確認

- Debug / ReleaseSafe: 各152/152。
- INIT chip/mode、byte単位frame分割、checksum破損、fragment、TLV長、protobuf overflow、
  古いUID、RPC ERROR、明示AP設定、secret TX bufferの消去、切断、deadlineを確認。
- 完全な合成RPC→association→DHCP Offer/ACKを実行。さらにZig実装とは独立に
  Scapy 2.6.1で生成した310-byte Offer/ACK fixtureを検証し、非zero UDP checksumの
  正常・破損を確認。これは実機packet captureではない。
- ZLint/format/shellcheck、RV32 codegen、native ELF 6種類、image checker 5試験を通過。
- Hosted用image監査はpower-enableと専用実行関数を要求し、AT-only imageを拒否した。
  文字列が最適化で即値へ変わるため、PASS文字列の単純検索は判定に使わない。
- 生成bin: 65,616 bytes、SHA-256
  `fe61cadae6e7f305e15a45744f26f8530646f21236be7bbc4010bc70a3fdd600`。
  ELF: `8e3bf000d0bbfef07d1331c453acc89849554663fbdbfedeb473a0ce388eb762`。
  SRAM予約78,400 bytes、未使用heap領域52,672 bytes。リンクされたRTOS/FP命令なし。
  これらはAP設定ファイルを指定せず、C6の保存APを使う候補のhash。

## 次の実機判定

USB再接続後に、P4の実際のchip/firmware/layout/OTAを識別・保存し、検証用slotから
候補を起動する。`NIHOS_C6_HOSTED_WIFI_PASS ip=...`、status=1/stage=12と
INIT識別・RPC・DHCP ACKが揃うことを確認し、試験前image/OTAへ復元する。
保存APが利用不能なら失敗理由を記録し、ローカル0600設定で接続先を指定する。
C6のflash更新はこの試験に含まない。

既存C6のRPC互換性、partial SDIO FIFO read、cold boot、I2C電源制御、cache/DMAは
まだ物理検証していない。mode tag不在は255（unknown）、version query非対応は
fw_known=0として残す。checksum=0の旧peer frameはuncheckedとして計数する。
DNS・TCP・Internet疎通や通常OSサービスへの統合は、この試験の合格に含めない。
