# C6へTCP/IP・BLEホストを集約する検証

2026-10-27。方針は[ADR 0029](../adr/0029-c6-network-offload.md)。
P4はnihos、C6はESP-IDF上の通信ファームとし、まずESP-AT＋SDIOを使う。
本体からWi-Fiで通信できることを目指し、PCは開発・測定時に使う。

### 実機工程の修正

通常のWi-Fi利用に外付けUSB–TTLは不要。内蔵C6の既存ESP-HostedへP4から
内部SDIOで接続できる。ESP-ATへの置換条件を、AP接続・IP取得全般の必須条件と
したのは誤りだった。次の実機工程は、既存C6を書き換えないSDIO/Hostedの識別・
version queryから行う。factory HostedでAP/IPを確認する場合、DHCPはP4側で処理し、
C6側TCP/IPオフロードの成功とは分けて記録する。最終的なC6オフロード方針は保持する。

ESP-Hostedには内部transport経由のC6 OTAがあるため、外部UARTだけを更新手段と
決めない。実際のC6版・RPC対応・partition適合を確認する。
[調査記録](../measurements/2026-10-27-c6-wifi-preflight.md#内蔵接続と更新経路の再確認)参照。

## 現在の到達点

- 実装済み：P4向け受信デコーダ、AT制御本体、型付きコマンド生成、分割TX、
  単一コマンドのdeadlineとepoch管理、初期交渉と切断復旧の状態管理。
- C6用SDIO＋Wi-Fi＋NimBLEファームのビルドが通過。上流SDK修正の実体も確認。
- P4側native SDIO boot driver、C6のFIFO/credit管理、専用CPU0プローブを実装・ビルド。
  [手順と制約](../../probes/c6-sdio/README.md)を参照。実機での通信は未確認。
- AP接続・DHCP有効化・接続状態・IPv4/gateway/netmask確認までのopt-in試験を追加。
  ホスト試験とnativeイメージ監査は通過。C6書き込み接続とAP設定が未確認のため、
  [実機preflight](../measurements/2026-10-27-c6-wifi-preflight.md)は未完了。
- ホスト試験対象：改行・NUL・偽のOKを含むTCP/BLE混在データ、容量超過、
  不正ヘッダ、途中切断、遅延応答、古いtokenの拒否。
- 未実装：IRQ駆動SDIOサービス、microSDとの共有調停、socket/BLEリソース表、アプリ接続。
- 未検証：C6用ファームの書き込み・起動、Tab5上の通信、同時動作、性能。

## C6用候補

上流ESP-ATの`v4.1.1.0`、commit
`7c092f9aee793d6dbfae31e7585637baa14fb4ce`を検証用に固定する。
C6用`IDF_VERSION`はESP-IDF
`8ad0d3d8f2faab752635bee36070313c47c07a13`を指定している。
P4用のSDKを流用しない。これは最新版という主張や本番採用ではない。

[C6ビルド手順](../../ports/esp32c6-at/README.md)に従い、専用の上流checkoutへ
設定overlayを適用する。ビルド結果は`build/c6-at/receipt.json`に記録する。
以下の設定は生成されたsdkconfigでも確認済み。

```text
CONFIG_IDF_TARGET_ESP32C6=y
CONFIG_AT_ENABLE=y
CONFIG_AT_BASE_ON_SDIO=y
# CONFIG_AT_BASE_ON_UART is not set
CONFIG_AT_SDIO_BLOCK_SIZE=512
CONFIG_AT_WIFI_COMMAND_SUPPORT=y
CONFIG_AT_NET_COMMAND_SUPPORT=y
CONFIG_AT_BLE_COMMAND_SUPPORT=y
CONFIG_BT_ENABLED=y
CONFIG_BT_NIMBLE_ENABLED=y
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=y
```

最初はTCP 1接続、BLE 1接続、TCP読み出し最大1024 bytesから始める。
接続上限・BLE MTU・受信バッファは測定後に増やす。C6用ESP-ATでは
BLE HID専用ATコマンドは有効にできない。キーボードは後段でGATT経由の
HIDプロファイル処理を追加する。今回はGATT通知の同時受信までを測る。

成果物には上流commit、実際のIDF commit、解決済みsdkconfig、partition table、
各binのSHA-256、ビルドログ、`AT+GMR`全文をまとめる。上流のAT coreや
無線ライブラリにはバイナリ依存もあるため、ファーム配布時は依存別のライセンスと
noticeを確認する。この変更では上流ソースやバイナリをnihosへ取り込まない。
ビルド成果物はignoredの`build/`に保存する。上流source/SDKも別checkoutとし、
上流が適用するSDK修正を記録する。[検証記録](../measurements/2026-10-27-c6-at-controller-build.md)参照。

## C6を書き換える場合の復旧経路

1. Tab5の識別、P4の実行中ファームとOTA slot、serial portの所有者を記録する。
2. 既存ESP-Hostedのversionと内部SDIO OTAの対応を調べ、実際のchip/flash、
   partitionと候補imageの適合を確認する。download端子は直接書き込み・復旧用の
   別経路であり、通常利用の前提ではない。P4 USBが直接C6 ROMへ繋がるとは仮定しない。
3. C6の既存flashをNVSも含めて保存し、読み直したhashが一致することを確認する。
   復旧するimage・offset・tool/versionを記録する。backupには認証情報が含まれ得る
   ためgitへ入れない。公式工場ファームも復旧候補として確保する。
4. P4の既存image・bootloader・partition table・SDを保持したまま、C6のみを変更する。
   P4のOTA切替だけではC6は復元されない。

SDIO配線はP4側CLK=12、CMD=13、D0=11、D1=10、D2=9、D3=8、C6 reset=15。
公式Tab5資料と対象基板で再確認する。初期化クロックから低速で始め、転送成功後に
クロックを上げる。microSDとは配線が別でもSDMMCの共有資源・割り込み・DMAを
調停する。MeOSソースのライセンス未確認部分はコピーしない。

## P4側の初期化と受信プロファイル

SDIOに来るバイト列をATストリームとして扱う。ESP-Hostedヘッダは付けない。
初期交渉でコマンドごとの成功を確認してから通常要求を許可する。

```text
AT
ATE0
AT+GMR
AT+SYSSTORE=0
AT+CWMODE=1
AT+CIPMODE=0
AT+CIPMUX=1
AT+CIPDINFO=0
AT+CIPRECVTYPE=5,1
AT+BLEINIT=1
```

AP接続は資格情報をログに残さない方法で別途行う。SSID/passwordの
引用符・comma・backslashをコマンドエンコーダでescapeする。文字列を
そのままATコマンドへ連結しない。`CWJAP`は長く待つ場合があるため、
BLEの定常測定前に接続を確立し、再接続中の通知も別途測る。

`+IPD,<id>,<count>`は読み出し可能量の通知。ownerがsocket IDを覚えて
`AT+CIPRECVDATA=<id>,<最大1024>`を送り、その応答を長さで読む。
`+NOTIFY`と`+INDICATE`も長さで読む。C6側で発生した通知はコマンドの
応答待ち中にもdrainする。デコーダのborrowed sliceは次のbyte投入前に
bounded queueへコピーする。先にアプリを直接呼ばない。

送信では`CIPSEND`の最初のOKでコマンド枠を解放しない。promptを待って
指定したbyte数を書き、SEND OK/FAILで完了する。BLE書き込みもpromptと
終端応答を区別する。timeout、途中切断、RX overflow、C6のready検出時は
gateをinvalidateし、デコーダをabort、全resource handleを無効化する。
古い受信byteを捨て、リンク再確立と初期交渉を完了してから新epochへ進む。

## 同時動作の合格条件

測定機器はTCP echo serverと、番号・送信時刻入りGATT通知を送るBLE peer。
これは測定設備であり、利用時に先生PCを必要とする構成にはしない。

1. TCP単独、BLE単独、同時、同時＋microSD/displayの4条件で同じ試料を測る。
2. TCPは番号とchecksumでbyteの一致・順序を確認。BLEは番号で欠落・重複を数える。
   改行、NUL、`OK`、`ERROR`、`>`、commaを含むpayloadを使う。
3. 初期目標は各条件10分、TCP 1接続、BLE 1接続・20通知/秒。
   これは未測定の目標。queue overflowを含む欠落はゼロ、TCP内容不一致はゼロ。
   遅延は測定点を明記しp50/p95/p99/maxを報告する。peerと時計を同期できない
   場合は送信からの片道遅延と呼ばず、echo RTTまたはP4内処理時間を測る。
4. C6 free/minimum heap、P4のSRAM、queue high-water、SDIO error、通信量を記録。
   利用可能なheap診断APIは採用SDK/AT構成で確認する。
5. AP切断、BLE peer切断、C6 reset、consumer停止を挿入し、bounded errorと
   再接続・再subscribe、古いhandleの拒否を確認する。回復時間は実測する。
6. HTTPSは別試験。正しいCA/hostnameで成功し、誤ったCA/hostnameで失敗すること、
   時計・証明書更新とTLS同時接続時のheapを確認してからアプリへ公開する。

実機レポートはP4/C6のimage hash、基板、AP/peer、config、期間、全失敗を含める。
ホストの合成ストリーム試験やRV32コンパイルを実機結果と混ぜない。

## 開発用確認

```sh
.tools/zig-0.17.0/zig build test
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
sh tools/run-static-analysis.sh
```

RV32確認は`tools/probes/c6-at.zig`からデコーダとgateを実際にcodegenする。
AT制御本体と型付きコマンド生成も同じprobeでcodegenする。
SDIO boot driverとATをつなぐ経路は`tools/probes/c6-sdio.zig`でもcodegenする。
P4ファームへのリンク、SDIO接続、C6との通信を確認するものではない。

ATの逐次実行や機能上限が測定要件に合わなければ、nihos側のアプリAPIを保ち、
C6側をversion付きbinary RPCへ置き換える。まずはATで必要性を判断する。
