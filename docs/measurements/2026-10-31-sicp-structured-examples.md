# SICP例題の構造化と読み取り専用カタログ

2026年10月31日。[学習体験の設計](../planning/sicp-interactive-learning.md)の第1段階。
`codex/sicp-structured-examples` で、読書実装の `c85d7ed` を基に実装した。
原checkoutの未コミット4ファイルと、他作業のworktreeには変更していない。

## 変更したこと

元XMLと編集manifestから、本文と例題のUTF-8 byte範囲を一緒に生成する。
25個のコード断片、21個の実験手順を収録し、隠れた補助コード4個は本文へ出さず
カタログに保持する。本文のページがコードの途中で切れても、例題はコード全体を返す。

コード、表示用出力、EXPECTEDは別フィールド。REQUIRESだけを準備の依存関係として
たどり、EXAMPLEは定義を試す呼び出しとして扱う。再帰版と反復版の同名定義を
一つの実験へ混ぜず、安定IDで原典と利用者の将来の草稿を結びつける。
コードの抽出に出力の数値を連結しない。

取得版・原典ファイルhash・NAMEまたはコードhashで編集manifestを照合する。
未分類コード、重複ID、不明/曖昧なselector、未解決参照、依存循環、表示専用コードへの
実行依存を生成時に拒否する。本文とカタログの組合せが古い場合もビルドを止める。

`assets/xy/sicp-learning.json` をMacアプリへ同梱する。
Tab5向けの既存XYREAD01パックには、ヘッダの予約領域から参照するXYLAB001表を追加した。
読書パックのヘッダ40/44 bytes位置は、例題表のoffset/lengthを示す。
従来の例題表なしパックも受け付ける。今回の例題表は6,259 bytes、読書パック全体は
2,900,967 bytes。既存フォントの字形収録を確認し、フォント本体を変えずに本文hashを更新した。

## 読出しの契約

`src/xy/learning_catalog.zig` は呼出し元が保持する不変のbyte列を借りる。
アロケータ、JSON解析、コードの評価を必要としない。
節・コード断片・実験の取得、安定ID検索、ページ範囲に交差する例題の列挙を提供する。
コードと参考出力を別スライスで返す。利用期間は元のROM/パックの所有期間内に限る。

形式の版、長さ、表の配置、文字列範囲、UTF-8、参照番号、本文内のanchorを検査する。
ID/名前128 bytes、コード/表示用出力4 KiB、EXPECTED 1 KiB、feature一覧1 KiBなどの
上限を生成側と読出し側で揃える。本文のlibrary SHA-256とmanifest SHA-256をヘッダへ保持する。
このhashはペアの識別用で、信頼できない配布元の真正性を保証する署名ではない。

全実験の実行対応は`unqualified`、参考値の採点利用は未承認とする。
Zig側も`execution_qualified`と`reference_approved`をfalseで返す。
例題表を読み出せることを、その例題が現行Scheme VMで動くこととは扱わない。
新しい読出しAPIはまだ読書UIから呼び出していない。

## 再生成と検証

```sh
python3 tools/xy_sicp.py
python3 tools/fonts/build-xy-reader.py --refresh-manifest
python3 tools/xy_sicp.py --check
python3 tools/xy_sicp_test.py -v
sh tools/build-xy-mac.sh
sh tools/build-xy-tab5-preview.sh
python3 tools/xy_reader_test.py -v
python3 tools/xy_tab5_reader_test.py -v
python3 tools/xy_workspace_test.py -v
zig build test -Doptimize=ReleaseSafe --summary all
sh tools/build-native.sh device
```

`--refresh-manifest`はフォントbytesの一致と実際のcmap coverageを検査する。
不足文字やフォント変更があれば失敗し、原典フォントからの再生成を要求する。
書籍全体を再生成する既存の`tools/xy-library.py`も同じコンパイラを利用する。
CIのMacジョブへ構造化・nativeカタログの契約試験を追加した。

今回の実行結果とhashは同日のevidenceディレクトリに保持する。
構造化試験は、原典照合、code/output分離、期待値の未承認、IDと本文順の安定性、
UTF-8位置、依存/使用例の区別、参照切れ/循環/範囲外/不正UTF-8の拒否を確認する。
実際に生成した表をZigで読み、ページ途中から完全なコードを取得する試験も含む。

通常deviceイメージはビルドとimage監査に成功した。image本体3,504,560 bytes、
primary heap 49,344 bytes、xy Flashコード60,592 bytes、読取専用データ2,948,324 bytes。
heap下限49,152 bytesを維持し、既存記録の通常読書版と同じheap量だった。
最終生成した例題表が、監査済みイメージに使用したパック内のbytesと一致することも確認した。

## 次の段階と残る条件

例題一覧、演習文書、学習専用VM、実行ボタン、メモ、本文への帰還、学習記録の保存は未実装。
処理系の除算・小数・末尾呼出しなども今回追加していない。
ファームウェアの書込み、実機起動、物理入力・表示の確認は今回行っていない。

基にした読書ブランチは、作業開始時のorigin/mainには未統合だった。
今回の変更をmainへ統合する際は、先行する読書実装と、その後のmainの変更を含む
候補で改めて統合チェックを通す。mainへ反映済みとは報告しない。
