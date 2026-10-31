# xyのホームとオフライン本棚

この記録はMac版の実装時点のもの。続く[Tab5接続と実機確認](2026-10-31-xy-tab5-reader.md)では、
ホーム・本棚・タッチによる読書を実機へ接続した。

Mac版xyが、空の編集バッファではなくホームで起動するようにした。
新規文書、UTF-8ファイル、3つのチュートリアル、読書、紙面の設定へ進める。
実装は `codex/xy-home-reader`、ベースは `dec310d`。
元の `/Users/masanork/repo/nihos` の未コミット4ファイルには編集を加えていない。

## 起動と操作

```sh
tools/build-xy-mac.sh
open build/xy-mac/xy.app
```

ホームの本棚と必要な日本語フォントはアプリに同梱する。開発用のgjsフォント
ディレクトリやインターネットがなくても、収録本文を読める。辞書検索は従来の
外部 `gjs.db` が必要。起動時のホーム、設定、ファイルダイアログはAppKitで、
本文は実機と同じZigの組版・RGB565描画からRGBAへ変換する。図版だけは
JavaScriptを無効にしたWKWebViewに、同梱のMermaid SVGを表示する。

| 操作 | 結果 |
| --- | --- |
| 新規ファイル / ⌘N | 新しい文書を開く。変更がある文書を置き換える前に保存・キャンセル・破棄を選べる |
| ファイルを開く / ⌘O | 4 KiBまでのUTF-8文書を開く |
| 文書を保存 / ⌘S | 保存先を選び、atomic writeで保存する。Source中は従来のApply & Save |
| ホーム / ⌘0 | 編集文書や読書中の位置を残してホームへ戻る |
| 編集中の文書に戻る | 読書前の本文・Undo・ルビ・入力状態へ戻る |
| 読んでいた本に戻る | 現在の本とページへ戻る |
| 表示設定 | 16–64px、縦横、明朝・ゴシック、明暗を選ぶ。次回起動にも引き継ぐ |
| 読書中の矢印 / Space / 前へ・次へ | ページ送り。章末から次章へ進める |
| 章選択 | 章の先頭へ移動する |
| 出典・図版 | 著者・出典・利用条件を表示。nihos書籍では、この章の図版も開ける |

## 収録内容と出典

- 夏目漱石『草枕』：青空文庫版の全13章、ルビ付き。
  入力・校正・底本の情報を保持し、画像だったJIS X 0213外字はUnicodeへ復元した。
  [原典](https://www.aozora.gr.jp/cards/000148/files/776_14941.html)。
- SICP：英語のScheme版、1.1、1.1.1、1.2.1の3節を収録する。
  日本語訳・全巻ではない。Schemeコードを保ち、XMLの索引・JavaScript側の本文を
  除き、数式をテキストへ変換した。図はキャプションで表示する。
  [原典と利用条件](https://sicp.sourceacademy.org/)。
  元XMLとCC BY-SA 4.0を `third_party/xy-reading/` に保持する。
- 『小さなOSを育てる』：`docs/book/book.cjs` の順番で32項目。
  出版用prepare処理で解決した本文・コード引用・章参照・図の説明を収録する。
  章の図版は同じリポジトリの生成SVGを開く。PDFのページ番号と、この読書画面の
  ページ送りは別物である。
- チュートリアル：新規作成と保存、文字の設定、Schemeでの自己編集の3項目。

Bunsenの同梱フォントはCC0の原典から読書用に生成した約1 MiBずつのサブセット。
収録パックに含まれるコードポイントの不足がないことをmanifestと試験で確認する。
原典・変換・ライセンスは `provenance.toml` と `third_party/xy-reading/NOTICE.md`、
フォントの入力・出力hashは `assets/xy/fonts/manifest.json` に記録する。
nihosのMITライセンスをSICP本文へ適用しない。

## 長文と編集の境界

Macホストは本棚JSONを読み、選択した章から候補ページを切り出す。libxyへ渡す
本文は最大4096 UTF-8 bytes、ルビ1024 bytes・64組。ホスト読書用の描画リストは
1024 glyph、実機の既存セッションは256 glyphを維持する。native監査も256版を
明示して許可し、1024版をnativeの許可対象にしない。

ページの末尾は実際のglyph配置と文字の送り幅で決める。IVS・結合濁点・グループルビ
を分割せず、本文とルビに異なる余白判定を適用する。大きな文字で候補が収まらない
場合は幾何級数で縮め、全長を再試行し続けない。英文の単語は行内に収まる範囲で
まとめ、長い識別子には文字単位の折返しを残す。表示設定を変えた際は、現在の
ページ先頭のUTF-8 byte位置を起点に組み直す。

読書モードでは文書編集、IMEキー、Schemeからの編集コマンドを拒否する。
元の編集文書はUndoとルビを含めて保存し、IMEの未確定状態も復元する。
通常の編集文書も描画と同じ4 KiB上限に揃え、保存したのに再読込できない容量差を
作らない。一般の巨大ファイル編集、読書位置のディスク永続化、全文検索は含まない。

## 検証

最終候補で次を実行した。ログは `evidence/2026-10-31-xy-home-reader/`。

```sh
python3 tools/xy_reader_test.py -v
python3 tools/xy_workspace_test.py -v
python3 tools/native_image_test.py
zig build test -Doptimize=ReleaseSafe --summary all
sh tools/build-native.sh device
shellcheck tools/build-xy-mac.sh
```

- 読書用試験8件：原典と書籍ソースのhash、全13章・32書籍項目、ルビ境界、
  フォントの収録文字、全収録章の先頭を24/64pxの縦横で開く試験、草枕第一章を
  最後まで連続して読む試験、英文の送り幅、読取専用、失敗時のページ保持、
  元の文書とUndoへの復帰を確認した。
- 既存ワークスペース結合試験16件成功。SQLite保存・世代の切替・エラー時復元・
  canonical framebuffer経路の既存試験を含む。
- Zig host testsは71/71 steps成功。変更した7 Zigファイルのlintは0 errors / 0 warnings。
  `zig fmt --check`、shellcheck、`git diff --check`も成功。
- 通常deviceイメージのビルドとnative構造監査が成功した。
- 実際のCocoa画面でホーム、草枕の縦書きルビ、SICPの英文折返し、書籍の章選択、
  図版ダイアログのSVG内容を確認した。新規文書を保存し、実ファイルのUTF-8が
  入力した `xy home test\n日本語の文書です。` と一致することも確認した。

**Macのホームと本棚の実装・検証である。Tab5の起動UI・SD上の本棚データ読出しへの
接続は未実装で、今回のnativeビルド成功をその実装や実機での読書成功とは扱わない。**
ファームウェアの書込みや実機起動試験は実施していない。

## 再生成

書籍やtutorialを変更した場合、パックとフォントの整合性試験が変更を検出する。
出版用の依存パッケージを用意して、次を実行する。

```sh
(cd docs/book && npm ci)
node docs/book/scripts/prepare.mjs
python3 tools/xy-library.py
python3 tools/fonts/build-xy-reader.py --source-dir /path/to/bunsen-build
```

アプリの通常ビルドは、チェックイン済みのJSON・フォント・SVGをコピーするため、
出版ツールやfontToolsを必要としない。CIのMacジョブにも読書試験を追加した。
