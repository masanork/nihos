# xy: Macの自己編集・共通画素描画とTab5実機確認

実行コードの最終コミットは `9443377bdfb8a579691a0a3e1a38dc59ee9d15a1`。
native描画のPR #87と、mainのPR #90（キーボード設定・SD所有権など）を含め、MacのSQLiteワークスペース、
英数字フォントと共通フレーム転送を統合した。後続の証跡コミットは実行コードを変更しない。

MacのSourceバッファでScheme定義を編集し、別VMで検証してからSQLiteへ世代保存し、
動作中のコマンドへ反映する。履歴復元、再起動時の再構築、競合検出も含む。
Macとnativeは同じ拡張Scheme runtime・view設定・render sessionを使う。
Macの保存adapterはシステムのlibsqlite3を使用する。nativeのSD書込み・SQLite永続化は未接続。

文字はホストOSのfont renderingへ渡さず、共通Zigのglyph解決、組版、ラスタライズ、
RGB565合成を通す。Mac向けRGBAは完成RGB565から展開するだけとし、
nativeの回転後フレームとMacの論理座標フレームを向き合わせ後に全画素比較する。
現在のウィンドウはCocoaであり、GPUI runtimeへの接続はまだ行っていない。

## 英数字と日本語

英数字はSource Code Pro Medium由来のOFL準拠subset「Nihos Code」を使う。
32..126の全ASCIIについて、元の固定TTFと8/25/64/96px・両方向のmaskとmetricが一致する。
25px時の送り幅は15px。runtime subsetは10,184 bytesで、元フォントとライセンス、
再生成スクリプト、manifestも保持する。日本語は両ターゲットとも同じBunsen recovery faces。
外部の完全フォントパックの有無で、device互換canvasの字形を変えない。

実機を見た利用者から「英語・日本語とも読める。英語も引き締まってる」と確認を受けた。
同時に「たまにちらつく」と指摘があり、以下の描画更新を修正した。
この目視確認は修正前の候補であり、修正後のちらつき消失を証明する観察として扱わない。

## ちらつきにつながる再描画の修正

背景ログのdirty通知がxyにも伝わり、文字が変わらなくても全画面を再描画していた。
さらにDMAが走査するframebufferを直接背景色で消し、その上へ文字を描いていた。

xyでは文書・表示設定・別画面による上書きだけを再描画理由とする。
PSRAM上の作業フレームへ描画を完了させ、成功とstack guard確認の後に、
変更のある64-byte範囲だけを走査用framebufferへコピーする。
空白化などの中間状態を公開せず、変更のない場合はcache writebackも要求しない。
失敗した描画は公開しない。serialのno-op入力の状態記録は描画とは独立して残す。

これはVSYNC同期のbuffer swapではない。操作中のコピーと走査の競合によるtearingまで
排除したという主張はしない。今回の自動判定は、無操作中の再描画停止と継続走査、
描画失敗0、DMAエラー0である。

## レビューで確認した回帰の修正

Macのworkspace再初期化後も外部辞書providerを接続し直し、起動時に登録したcallbackを保持する。
状態欄はIMEがreading/selecting中なら変換候補を優先し、idle時だけworkspace通知を表示する。
callback経由の2候補取得、候補切替・確定、通知と候補の画素優先順位を実dylibで検証した。

共通render requestへDocumentのruby arenaとspanを渡す。表示窓の端がgroup rubyを横切る場合は
親文字の範囲まで窓を広げ、窓内の読みだけを詰め直し、本文・読みのoffsetを補正する。
長い本文がruby字形の一時領域を上書きする既存問題を別配列で修正し、
段落ごとのruby rangeも補正した。非ゼロoffsetの表示窓、140文字以上の本文、複数段落、
両方向、ruby付きnative/logical全画素一致を回帰試験に含める。

## 最終候補の実機確認

対象はTab5、ESP32-P4 revision v1.3、MAC `e8:f6:0a:e2:e8:9c`、16MiB Flash。
書込みlockとserial exclusive ownershipを取り、候補を別領域に凍結し、
書込み前後にhashとFlash bytesを照合した。入力はserial UTF-8である。

| 確認 | 結果 |
| --- | --- |
| 起動・文書・カーソル・CRLF・IVS削除・undo・help・read-only buffer・Scheme・warm reset | 56状態観測が一致 |
| 日本語、横書き/縦書き、文字色/背景色、36pxから25px | 4描画観測、失敗0 |
| 描画stack | 最大77,936 / 131,072 bytes、guard保持 |
| 最終候補の無操作30秒 | 30観測、render_frames=32で不変、scanout +1,751、DMAエラー0 |
| 同じ修正の120秒観測（lint注釈整理前の候補） | 120観測、render_frames=32で不変、scanout +7,177、DMAエラー0 |
| 原Flashへの復元 | 両試験とも変更した全spanを復元しverify_flash成功 |

最終trace application SHA-256:
`c7a20b8df408f25636d4790a36e44600c2f125b1a182ac156c07fd68959afa4c`。
通常版application SHA-256:
`2731b1d412c8139aebcf271c68696cf90c199d7eab39cd3633f9496399b7a737`。
実機実行はtrace版、通常版はbuild/image auditまで確認した。

最初の混在サンプル試験では、直前のCRに続くLFの正規化を試験側が数え違えて失敗した。
文書hashは先頭LFを除く期待値と一致しており、送信を明示CRLFへ修正した後は56観測が通った。
失敗試験も含め元のFlashへ復元した。生のFlashバックアップとネットワークを含む全serial logは
私有領域に保持し、公開証跡にはxyの行と復元結果だけを含める。

## 常駐資源

| 項目 | bytes | 意味 |
| --- | ---: | --- |
| primary SRAM heap | trace 49,216 / normal 49,344 | linker確保量。実行時freeではない。48KiB基準49,152を維持 |
| 作業frame追加分 | 1,843,200 | 1280×720×RGB565、PSRAMに常駐 |
| xy描画leaseのpayload | 2,958,656 | cache/workspace + 128KiB stack + 作業frameの実測 |
| xy描画leaseのpool予約 | 4,194,304 | size poolが占有する量の実測。追加前は2MiB予約 |
| trace xy Flash code / RO data | 44,448 / 269,944 | native image auditによる |
| normal xy Flash code / RO data | 43,888 / 269,944 | native image auditによる |

走査用framebufferは既存のものを借用する。追加frameをprimary SRAMへ置かない。
primary heapの基準に対する余裕は64 bytesなので、今後のnative変更も同じ監査を通す必要がある。

## host・emulator・CIの範囲

- Debug: 69/69 build steps、未cacheの823/823 tests成功、残りはcache再利用。
- ReleaseSafe: 69/69 build steps成功。変更で未cacheだった763/763 tests成功、残りはcache再利用。
- Python discovery: 522件成功。
- Mac実行ファイル/dylibによるSQLite lifecycle・描画結合試験: 16件成功、描画skipなし。
- static analysis: fmt、zlint 0 errors / 0 warnings、shellcheck、codegen、6 native ELF監査成功。
- RV32 ESP-EMU: 39観測。編集・IVS・undoの全画素一致、Scheme、設定変更と拒否、読み取り専用buffer、日本語描画が成功。
- GitHub ActionsはPR #89の最終headに紐づく結果を参照する。host/CI/emu結果を実機の代用にしない。

cold power cycle、実キーボード、全日本語/全IVSの収録、nativeの保存と電源断復旧、
GPUI runtimeは今回の確認範囲に含まない。完成frameの数値一致はパネルの色特性や
操作タイミングの一致まで意味しない。

[証跡index](evidence/2026-10-31-xy-native-pixel-landing/index.json)、
[最終実機結果](evidence/2026-10-31-xy-native-pixel-landing/physical-result.json.gz)、
[120秒観測](evidence/2026-10-31-xy-native-pixel-landing/long-idle-result.json.gz)。
Macでの操作は[ワークスペース手順](2026-10-31-xy-mac-workspace.md)、
画素転送の初期記録は[Mac pixel host](2026-10-31-xy-pixel-host.md)を参照。
それらの初期版にある外部font依存・512 glyph上限・別runtimeの記述は、
本統合ではbundled recovery faces・cursor追従240 glyph viewport・共通runtimeへ更新されている。

CIのhost品質ジョブは最終SQLite RV32 linkの途中で15分上限に達して打ち切られた。
先行工程の成功を保持し、検証内容を削らず、このジョブの時間枠だけを25分へ変更した。
