# Mac版xyのScheme自己編集とSQLiteワークスペース

Mac版xyで、xyのSourceバッファにあるScheme定義を編集し、動作中の
コマンドへ反映する初期実装。正本はコメント・改行を含むUTF-8原文で、
SQLiteに世代ごとに保存する。アプリ再起動時には選択中の世代を読み込む。

対象は単一の `user/init.scm` と、その定義・登録コマンド。Zig製の編集・
描画エンジンやScheme処理系そのものを端末上で再コンパイルする機能ではない。
Tab5の `sqld` 接続・SD保存・電源断試験は今回の対象外で未実装。

## 起動と操作

```sh
tools/build-xy-mac.sh
open build/xy-mac/xy.app
```

既存Macホストと同じ外部Bunsenフォントパックと `gjs.db` を利用する。
現時点のホストは `/Users/masanork/repo/gjs/data/output/` の資産を参照するため、
アプリ単体を他のMacへ配布する段階ではない。辞書DBは読取り専用のまま。
書込み用DBは通常 `~/Library/Application Support/nihos/xy/workspace.db` に作成する。
別のDBを使う場合はアプリ内の実行ファイルへ `--workspace /path/workspace.db` を渡す。

1. **Source / ⌘E**: 文書を保持し、同じxy描画・Documentでソースを開く。
   ソースでは文字をそのまま入力する。⌘Aで全体を選び、⌘Vで置換できる。
2. **Apply & Save / ⌘S**: 検証した定義を新しい世代として保存し、その場で反映。
3. **Source / ⌘E**: 文書へ戻る。未保存のソース草稿はメモリに保持する。
4. **Run Command / ⌘R**: 登録コマンドまたは引数なし関数の名前を指定して実行。
   初期定義の `stamp` は文書へ文字列を挿入する。ソース編集中なら文書へ戻って実行する。
5. **History / ⌘B**: 過去の保存世代を選択し、動作と次回起動時の版を戻す。
6. **Reload / ⌘L**: 他のセッションが保存した最新の版を読み直す。

例としてSource全体を次の定義へ変更し、保存後に `stamp` を実行する。

```scheme
(define (stamp)
  (buffer/insert! "xy live edit"))
```

未反映の草稿がある状態で終了・履歴復元・再読込みを行うと、破棄するか
編集を続けるかを選べる。通常の文書はこの段階ではRAMのみで、DB保存対象はソース。

## 実装の境界

- `scheme_runtime.zig` は別ブランチの既存コミット
  `7767c8c8e2d41e0030be33f81b502d0851c959bb` から変更せず再利用した。
  旧 `scheme_bridge.zig` の表示操作用S式ディスパッチとは独立した、永続定義と
  lexical closureを持つ共通の限定Scheme実行系である。
- `live_workspace.zig` はOS・SQLiteへ依存しない。候補環境の構築、実行環境の
  差替え、対話評価失敗時のVMと文書の復元を担う。
- `include/nihos_xy_workspace.h` はソース取得・世代保存・有効版選択の契約。
  現在の実装は `tools/xy_workspace_sqlite.c` のMac用SQLite接続だけ。
  Tab5は将来この意味を `sqld` 要求へ対応させる。Macから直接SDへ書く設計ではない。
- `tools/xy_mac_host.m` のGUIと検証CLIは同じ保存・反映の調停関数を使う。
- ソース読込・反映とコマンド実行は同期処理。DBのbusy timeoutは250 ms。
  ソースやコマンド名をSQL／Scheme文字列へ連結せず、bind／名前検索を使う。

## 保存・失敗・復旧

反映順序は、別のVMで定義を構築 → SQLiteの `BEGIN IMMEDIATE` で期待する
有効世代を確認 → ソース追加と有効世代更新 → `COMMIT` 成功 → 準備済みVMへ差替え。
DBの世代とRAMを一つのトランザクションと見なさない。commit直後にプロセスが
終了した場合は、次の起動で保存済みソースから再構築する。

構築中のバッファ編集・システム操作は拒否する。関数の中へ書く編集操作は
コマンド呼出し時に実行される。構文・実行・DBエラーで保存が失敗した場合は
現在の実行環境とDBの有効世代を維持する。候補全体を新しい環境へ読み込むため、
削除した定義や登録コマンドは残らず、再反映時には変数・クロージャの状態も初期化する。

対話評価とコマンド実行ではVMと文書を退避し、途中でエラーになった場合は
両方を復元する。これはMacホスト向けの有界な複製であり、Tab5の常駐予算へ
無検証で持ち込まない。

保存済み定義が読み込めない場合も内蔵定義で起動し、DBの原文と履歴を保持する。
`--safe` は正常なユーザー定義も実行せず内蔵定義を使う。ソースは明示的な
保存まで変更しない。不正UTF-8は通常のDocumentへ開けないので、外部から
正常なソースを保存し直す必要がある。

SQLiteは別のapplication ID／未対応schemaを拒否する。世代は保存APIからは
上書きせず、履歴選択で過去の版を有効にする。別セッションの更新後に古い版を
上書きしようとすると競合になり、Reloadで更新を確認してから保存する。

## 制約

- 完全なR7RSではない。256 cells、文字列・名前ごとに64 UTF-8 bytes、
  評価深さ24、評価step 1024、登録コマンド16、ソース4096 bytesの上限がある。
  ソースの長さ以内でもcell上限に達することがある。macro、module、継続、
  proper tail call、完全な数値体系はない。
- コマンド実行で使える編集操作は挿入・書記素移動・undo。システムビュー要求と
  undo履歴破棄はこのMac adapterでは拒否する。
- ソース編集には既存のxy canvasを使う。高度な選択・スクロール・ファイル操作を
  備えた開発環境は未実装。現在の描画リストは512 glyph上限で、それを超える
  大きな草稿は表示エラーになる。起動・永続化の4 KiB上限と描画上限は異なる。
- ソース用VMは通常のMacアプリの権限で動く。PMP／U-mode保護を追加したものではない。
- `libsqlite3` はMacのシステム版を利用。Tab5版との同一バージョンや
  バイナリDB互換性を認定する試験ではない。

## 検証

```sh
python3 tools/xy_workspace_test.py -v
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe --summary all
```

結合試験は一時DBと実際のMac実行ファイル／dylibを使い、別プロセスでの
原文復元・変更したコマンドの実行、履歴選択後の分岐、保存エラーとbusy、
競合、空のソース、不正な保存定義からのfallback、安全起動、無関係なDBの
拒否、同一プロセスのVM／文書の復元を確認する。外部フォントが存在する環境では
ソースとコマンド出力を実際のRGBA描画まで通す。

共通部分のテストは、再定義、削除した定義の除去、副作用を伴うロードの拒否、
評価失敗時の定義と文書の復元、反復再読込み、極端なカーソル移動を含む。
実フォントを使った画面確認で空白のcmap欠落がフレーム全体を失敗させる問題を
確認し、空白・タブ・全角空白の空のbitmapとadvanceを提供した。また16.16変換の
中間積をi64へ広げ、大きい字形のオーバーフローを回帰テストにした。

元のmain checkoutにあった4ファイルの未コミット変更は取り込まず、
`codex/xy-mac-workspace` の独立worktreeで実装した。これにより別作業の
ハノイ・組版修正の所有権と内容を保つ。

最終確認では結合試験 **13件成功**（実フォント描画を含む）、Zigのテストビルド
**63/63 steps成功**、変更した5 Zigファイルのlint **0 errors / 0 warnings**。
`zig fmt --check`、shellcheck、`git diff --check` も成功した。
実際のCocoaウィンドウで、ソースの置換・保存、プロセス再起動後の `stamp` による
`xy live edit` の表示、2世代目の保存、Historyから1世代目への復元を確認した。
原mainのHEAD・status・未コミット4ファイルのSHA-256は作業前と一致した。

ソース・実行ファイルのhash、試験ログ、GUI操作後の世代内容は
[evidence/result.json](evidence/2026-10-31-xy-mac-workspace/result.json) に記録した。
GUI観察は手動操作の記録であり、Tab5や電源断の証跡へ読み替えない。

SQLite APIの参照: [transaction](https://sqlite.org/lang_transaction.html)、
[prepared statementへのbind](https://sqlite.org/c3ref/bind_blob.html)。
