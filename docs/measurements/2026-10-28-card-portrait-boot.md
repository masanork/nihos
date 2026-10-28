# カード版の縦組み起動画面

実装: `c79179e`。ベースは `c54d9dd` にカード表示のベースSRAM割当変更を取り込んだもの。ESP32-P4 rev1.3でカード通信のないwarm-reset試験を1回行い、起動・待機を含む15回の全画素比較で不一致0を確認した。目視確認は別途保留。

[実際の描画コードによるプレビュー](2026-10-28-card-portrait-boot.png) / [画像・ソース・検査結果](2026-10-28-card-portrait-boot.json)

## 動作

DISPLAY=9/10/11では、基盤のPSRAM・ボード・タスクの検査後、カード機能の準備を始める前に縦組み画面を表示する。「丹穂」と既存の万葉集を縦組みにし、墨色・朱色の意匠を維持した。リセット直後から全起動段階を表示する変更ではない。

写真デコーダ、暗号セルフテスト、タッチなどの準備中は、DMAが既にコピーしたSRAM画面を参照し続ける。実際の準備が完了したら、既存のEOF・video tail drainを経由して待機・PIN・プレビューへ移る。見せるための固定待ち時間や、パネル・PHY・バックライトの再初期化は追加していない。準備失敗時は既存の機密情報終了処理へ進み、PINを再試行しない。

共通RGB565/A8 compositorは `fe84f47:src/graphics/surface.zig` から取り込んだ。ブレンド式は同じで、補助関数の `inline` 指定のみ追加した。専用フォント試験用worktreeの作業中ファイルは取り込んでいない。

文字は固定版FreeType 2.14.3 / HarfBuzz 15.0.0と、SHA-256固定のBIZ UD明朝・ゴシックで事前生成した。TTB shapingによる字形を固定の列へ配置する。実行時は4bit被覆のRLEを720B以下の1行A8へ展開し、共通surfaceでRGB565へ合成する。全文字の展開用buffer、フォントworker、TTFファイルは起動経路に不要。SIL OFLの原文を `src/graphics/card_boot/` に同梱した。

## SRAMとFlash

静止画ではPINの点と確認ラベルを二重化する作業領域が不要なので、stride=0として確保・描画を省く。静止画からのPIN更新はC側でも拒否する。PIN画面では従来の二重領域を使用する。

実際のZig描画・プランから得た735記述子は47,040B、再利用後の画素は206,344B、動的テクスチャは0B。計253,384B（約247.45KiB）。フォント予約を除いた128KiB + 124KiBの範囲に収まることを、実際のC容量検査コードで確認した。割当先のアドレスは引き続きベース管理側が決める。

固定マスクは17,930B。mask/metaを既存のread-only record領域へ配置し、イメージ検査でELFのmask範囲とSHA-256を照合する。1MiBのカード用アプリ領域、ベースの160KiB primary / 56KiB stack、最低48KiB heapの条件は変更していない。新しい背景色付きプラン生成と起動・切替・消去の前景コードはFlashへ配置し、IRQのDMA再開処理は変更していない。

## 検証

- Python 242件、Zig Debug / ReleaseSafe、fmt / ZLint / shellcheck、および既存6構成のRV32 ELF検査に合格。
- 実際のRGB565/A8描画コードをホストで実行し、原寸PNGを目視確認。geometry不正時の非破壊性、strideとguard保持、共通surfaceのブレンド・クリップを確認。
- 実際のboot rasterとsparse planをCへ渡し、フォント予約を除いた容量で通ることを確認。カードやPINは使わない。
- カードなし実機試験用のイメージには、スプラッシュと待機画面をDMAが参照する実画素と比較する2段階のlogを追加。これらは未実行。検査ツールは未検査・画素不一致・frame停滞を拒否し、起動handoff 1回と既存の12遷移を区別する。

| device構成 | primary heap | 画像・loader・source検査 |
| --- | ---: | --- |
| PIN表示 DISPLAY=8 | 59,712B | 合格 |
| 従来読取 DISPLAY=9 | 50,048B | 合格 |
| 写真付き読取 DISPLAY=10 | 49,536B | 合格 |
| カードなし画面遷移 DISPLAY=11 | 57,728B | 合格 |
| 自動検知・読取 DISPLAY=11 | 50,048B | 合格 |

上記の表はビルド・イメージ検査。下記の実機試験と区別する。調査用にheap assertionを緩めた別ELFも作ったが、表の合格画像と実際に書き込んだ候補は元の48KiB assertionでビルド・検査したもの。調査用ELFは書き込んでいない。

## カード通信なしの実機試験

別のリソース計測がポートを取得していた最初の試行は、排他取得で停止し、書込み・リセットとも行わなかった。その計測の3回完了と元のファームウェアへの復元・照合、ポート解放を確認してから、本試験の所有権を取得した。global owner記録・flock・serial exclusive・TIOCEXCLを、機体確認から書込み・照合・captureまで保持した。

機体はESP32-P4 rev1.3、factory領域1MiB、OTA選択領域なし。元の読取版のアプリSHA-256 `b9ae2f715ccb8081eb5300687eb354471d23ff23982530c200129d9aef69041a` を照合した。新候補はELF SHA-256 `c1bf02c5874bfd3c442dcb72e70250b313ae0f71e645b8fbd833b1a38eff9d64`、アプリSHA-256 `100c6238e3b75324470ed31485b988955a7d1229fb08a9a6a3a0e50abe243718`。bootloader・partition table・appの3領域を照合した直後にwarm resetしてcaptureした。

- スプラッシュ、待機の2画面と、既存の13回のDMA実画素比較は全て不一致0。
- 起動handoff 1回と、自動のPIN・券面・詳細・通知の12遷移を確認。
- パネル初期化1回、バックライト消灯0回、表示fault 0。最大video pauseは15,526µs。
- 表示領域は実際の貸出値 `0x4ff40000..0x4ff60000` と `0x4ff6e000..0x4ff9d000`。固定の旧アドレスを前提にせず検査に合格。
- カード操作・PIN送信0。画像はread_enabled=falseかつscene_exercise=trueで、カード通信の関数がリンクされていないことをイメージ検査済み。

最初のログ検査は、新設した2つの `NIHOS_NATIVE_CARD_BOOT` 進行記録を未承認のboot headerとして拒否した。検査ツールを `2338c56` で修正し、同じ凍結ログ・同じイメージを再検証して合格した。許可するのは画像で宣言された2記録と既存boot headerの順序だけで、追加ROM banner、余分な記録、別firmwareのheaderは引き続き拒否する。回帰テスト243件と静的検査に合格。元の拒否記録も私有のcapture一式に保持している。再検証のための再書込み・再起動は行っていない。

[boot log](evidence/2026-10-28-card-portrait-boot/boot.log) / [image audit](evidence/2026-10-28-card-portrait-boot/image-audit.json) / [検証結果](evidence/2026-10-28-card-portrait-boot/report.json) / [証拠の条件とhash](evidence/2026-10-28-card-portrait-boot/qualification.json)

現在はカード通信のないテスト画面を残し、後続resetなしでシリアル排他を解放した。通常の読取版にはまだ切り替えていない。目視による点滅・行ずれ・欠け、冷起動、表示終了時のnative SRAM返却は、このcaptureでの合格範囲に含めない。

## 再生成と残る統合

```sh
python3 tools/design/preview-card-boot.py
python3 -m unittest tools.native_notice_test tools.native_scene_test
NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=11 \
  NIHOS_NATIVE_CARD_AUTO_PROBE=1 NIHOS_NATIVE_CARD_SCENE_EXERCISE=1 \
  sh tools/build-native.sh device integer
```

固定文字を再生成する場合は、既存graphics-probeの固定版ホストライブラリへ `tools/design/shape-mask.cpp` をリンクし、`tools/design/card-splash-assets.py --probe BUILD --renderer RENDERER` を実行する。フォントSHA-256が一致しなければ生成を拒否する。PNG生成のみPython Pillowが必要で、通常のnativeビルドには不要。

今回は共有surfaceと固定文字までの統合。FreeType/HarfBuzz workerの起動・アプリ要求接続、TTF供給、12MiB試験用Flash配置との統合は残る。予約除外後の静止画が収まることは、workerとカードの結合ファームウェア全体の成立を示さない。待機・PIN・券面の新デザインも今後の作業。
