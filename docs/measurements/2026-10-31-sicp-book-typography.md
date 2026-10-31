# SICPの本文とコードを書体で分ける

2026年10月31日。実装候補 `4c67eef0`。
SICP学習セッションの[PR #99](https://github.com/masanork/nihos/pull/99)への追加。
従来はASCIIでSource Code Proを優先するため、本文まで等幅になっていた。

## 表示の変更

| 対象 | 書体と組版 |
| --- | --- |
| SICPの英語本文 | Century Schoolbook L系のTeX Gyre Schola 2.005を基にしたプロポーショナル書体 |
| コード、参考出力、SCHEMEINLINE、ブロック数式 | Source Code Pro。字下げを保つ |
| 日本語の本文・通常文書・演習文書 | 既存の書体・表示設定を維持 |

SICPだけは空のルビ領域を取らず、行間を文字サイズの1/5以内、空行の送りを通常の1/4へ詰める。
文字サイズを縮小せず、字幅と余白を整理する。通常の英単語は途中でページを切らず、長大なトークンは進行を優先する。
本文bytes・例題ID・原典位置を変更せず、表示を変える。元checkoutの4ファイルは保持した。

[変更前の本文](sicp-book-typography-2026-10-31/prose-before.png) /
[変更後の本文](sicp-book-typography-2026-10-31/prose-after.png)

[変更前の混在ページ](sicp-book-typography-2026-10-31/mixed-before.png) /
[変更後の混在ページ](sicp-book-typography-2026-10-31/mixed-after.png)

上記は同じ32px・横書き、Mac ABIの実際の共有描画から得た1280×720のframebufferである。
本文書体とコード書体は、独立したフォントAPIで別画像を合成したものではない。

## 密度の実測

導入節のprintable ASCII 2,566文字について、元のTTFのadvanceを合計した。
Source Code Proで1,539.6em、Scholaで1,202.149emだった。
字幅は約78.1%、同じ行幅に入る文字数は平均字幅換算で約1.281倍。
これは字幅の比較であり、ページ全体が一律28%増えるという意味ではない。

行間・ルビ領域・空行の調整も含む実ページ比較は、導入節が458→810 UTF-8 bytes、
コードの混在例が160→229 bytesだった。同じ先頭位置・32pxで比較し、詳細なRGBA hashを
[結果JSON](sicp-book-typography-2026-10-31/result.json)へ記録した。

## 原典構造を描画へ渡す

英文の見た目を推測する正規表現には頼らず、XMLのSNIPPET・出力・SCHEMEINLINEから
コード範囲を生成する。SCHEMEは言語分岐の文章も含むため、文中コードはSCHEMEINLINEだけを使う。
本文の正規化後にUTF-8範囲を測り、XYLAB001 version 2にsection/start/endの追加表を保存する。
コードと出力は表示上同じ等幅でも、実行候補としては別のままである。
version 1の読み出しも維持し、書体範囲を持たない旧版は従来表示へ戻す。

ページの範囲とコード範囲を交差させ、配置と描画に同じ字幅を使う。
書体は共有TrueType rasterizerで描き、本文・コード・日本語fallback用にcacheのstyle IDを分ける。
Macは次ページ候補と表示中ページの書式を分離し、無効なページ候補でも直前の表示を保つ。

## 書体の由来と再生成

[TeX Gyre Schola](https://ctan.org/pkg/tex-gyre-schola)のCentury Schoolbook L系デザインを採用した。
OTF sourceはSHA-256を固定して保存し、fontTools 4.60.2でLatin文字へsubset、
cubic outlineを最大誤差1 font unitのquadratic outlineへ変換した。
派生名は `nihos Book Serif` とし、TrueType版は65,292 bytes。
GUST Font License / LPPL 1.3c、作者表示、上流manifestと変更manifestを同梱する。
OS付属のCenturyフォントを複製する実装ではない。

```sh
python3 tools/fonts/build-xy-book-serif.py
```

再生成でTTFがbyte単位で一致することを確認した。由来と生成hashは
[src/graphics/serif/manifest.json](../../src/graphics/serif/manifest.json)を参照。

## 検証と容量

書体分離5試験、読書Mac 10・Tab5 10、演習7、workspace 16、教材構造12、
image監査の正負42試験が成功。実データを読むZig catalogueは6試験、
書体と共通rasterizerを直接通す試験は8件成功した。
全体のReleaseSafeとstatic analysisも成功し、生ログを結果JSONと同じディレクトリへ保持した。
ReleaseSafeは75/75 steps成功。cache利用を含むため、ログの実行件数を全件総数とは扱わない。

nativeの固定描画容量は512から1,024 glyphsへ変更した。無制限に本文を展開せず、
候補はMac 900文字、native 960文字までとし、収まる範囲へ縮める。
workspaceの2MiB上限、256KiB foreground stack、primary SRAM heap下限49,152 bytesは維持した。
候補のworkspaceは1,667,376 bytes、primary heapは49,600 bytes。
imageは3,611,088 bytesで、4MiB factory partition内に収まる。

stackの静的調査には未導出フレーム・未解決転送が残り、全呼出し鎖の証明はしていない。
Tab5実機のstack watermark・入力・表示は未検証で、mainへの統合は行っていない。
Macの新しい独立bundleは起動したが、UI自動化がcgWindowNotFoundでウィンドウを取得できず、
今回のMac証跡はABIと共有framebufferの実行結果として区別する。

再現確認：

```sh
sh tools/build-xy-mac.sh
sh tools/build-xy-tab5-preview.sh
python3 tools/xy_typography_test.py -v
python3 tools/xy_learning_test.py -v
python3 tools/xy_reader_test.py -v
python3 tools/xy_tab5_reader_test.py -v
python3 tools/xy_sicp_test.py -v
python3 tools/xy_workspace_test.py -v
python3 tools/native_image_test.py -v
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
sh tools/run-static-analysis.sh
sh tools/build-native.sh device
```
