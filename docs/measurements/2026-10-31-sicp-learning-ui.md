# SICPを読みながら試すRAM学習セッション

2026年10月31日。[設計の第2段階](../planning/sicp-interactive-learning.md)を実装した。
読書基盤を統合したorigin/main `0cb0ee4f` を基に、教材構造化と演習UIをまとめた。
実装候補は `49b92658`。通常checkoutの既存4ファイルには変更していない。

## できること

読書画面の「このページの例題」または `e` から例題を選び、コードを編集して実行できる。
`(+ 137 349)` を `(+ 137 350)` に変更すると487を表示する。本文の参考値486は
実行コードへ混ぜず、変更後の結果を採点しない。
Esc /「本文へ戻る」で同じ本文位置へ戻り、同じ例題を再び開くと草稿とメモが残る。

Macは例題選択ダイアログと操作バー、Tab5は例題一覧・キー・タッチ入力を使う。
コード・メモ・結果の画素は共有のZig描画を通す。演習だけ横書きにし、読書の
縦横・書体・文字サイズ・ページ履歴を変更しない。通常文書・Undo・エディタ拡張VMも保つ。

本文と例題の構造化は[第1段階](2026-10-31-sicp-structured-examples.md)を継承する。
25断片・21実験のうち、整数式9ケースを実行対象にした。他の12例も選択・編集できるが、
実行は未対応と表示する。コードを定義できるだけでは、factorial等の実験対応と扱わない。
参考出力の専用UIは未実装で、現在は本文で参照する。

## 状態と評価の境界

共有の `learning_session.Session` は草稿24個を保持する。各草稿は独立したコードとメモを持ち、
1文書4,096 UTF-8 bytes、Undo 256操作・削除退避2,048 bytes。満杯時に既存の草稿を追い出さない。
入力のUTF-8・容量・Undoの検査が失敗しても、元の草稿を保持する。
「原文のコード」はUndo可能な編集であり、「環境をリセット」はコードやメモを消さない。

一つの稼働VMと一つの候補VMを使い、正常終了時だけ候補を採用する。
失敗した評価で定義や変数更新を途中まで反映しない。エラー・資源上限後も実行できる。
同じ例題では定義を保持し、別の例題を実行するとVMを初期化する。以前の草稿・メモ・結果は残る。
メモ表示中の「実行」もコード文書だけを評価する。結果にはコードrevisionを付け、編集後は古い結果と示す。

学習hostは通常文書、ファイル、SQL、デバイスを公開しない。mainのカメラbuiltinは
学習hostにproviderがないため利用できず、エディタ操作も拒否する。
整数32bit・depth 24・step 1,024・heap 256 cells・文字列64 bytesという既存VMの制約を継承する。
除算、小数、`cond`、末尾呼出し、非同期評価・キーによる中断、R7RS対応は追加していない。

## メモリとnative候補

固定表示用領域の末尾には学習セッションを置かない。既存の描画用PSRAMリースへ含める。
32bitターゲットの描画・読書・学習workspaceは1,646,800 bytesで、従来の994,640 bytesから
652,160 bytes増えた。2MiBの上限はruntimeとcompile-timeの両方で確認する。
この増加はアプリ所有workspaceであり、システムのSRAM常駐量とは別である。

| 通常device候補のビルド監査 | 値 |
| --- | ---: |
| image本体 | 3,521,632 bytes |
| primary SRAM heap | 49,600 bytes |
| heap下限 | 49,152 bytes（変更なし） |
| xy Flashコード | 76,352 bytes |
| xy読取専用データ | 2,949,604 bytes |
| 学習込みworkspace | 1,646,800 bytes |

リンク時のSRAM下限違反を調査し、全体のエラー名テーブルを生成する呼出しを有限な学習用表へ置換した。
文書の共有変更処理4関数はforeground専用Flashへ配置し、関数名と文書容量をimage監査で限定する。
調査用に下限検査を外した中間ELFを作成したが、納品候補は元の下限を復元して通常ビルドをやり直した。
上表と証跡は通常の下限検査を通した候補だけを示す。
PSRAMの実測使用量・予約量・描画stackのhigh-waterは今回の実機では測定していない。

## 検証

| 確認 | 結果 |
| --- | --- |
| 演習ABI・実Tab5描画の往復 | 7試験成功。全9整数例、編集487、日本語メモ、元の本文画素、通常文書Undo、未対応例、失敗時の環境維持を確認 |
| 読書・ページ境界 | Mac 10、Tab5共有core 10試験成功 |
| SQLite workspace回帰 | 16試験成功 |
| 教材構造・生成されたZigカタログ | Python 12試験成功。実データを読むZig 5試験を含む |
| native image監査の正/負例 | 42試験成功 |
| native入力の所有 | 実scratch.ModelへASCII・日本語serial・Backspace・Undo・メモ切替・Escを渡す試験成功 |
| Zig Debug全体 | 75/75 steps成功（cacheを含む） |
| Zig ReleaseSafe全体 | 75/75 steps・1045/1045試験成功 |
| 全体static analysis | fmt・ZLint・shellcheck、broker/checkpoint/architecture契約、6種類のnative ELF監査成功 |
| Mac・Tab5 preview・通常device | 最終候補のビルド成功、通常image監査成功 |

Debug/ReleaseSafeログには `failed command: .../test ... --listen=-` の診断が出たが、終了値0でrunnerの
最終集計は全steps成功だった。途中の診断を削らず、実行済み試験数とcache利用を含む生ログを保持する。

Macの最終候補を専用bundle ID・検証用workspaceで起動し、SICPの加算例を選択、⌘A→貼付で変更、
⌘Rで487、日本語メモ入力、Escで元の縦書き本文への復帰を実画面でも確認した。
framebuffer画像はABIで再現したものを別途保持する。
[結果表示](sicp-learning-ui-2026-10-31/exercise.png)と
[日本語メモ](sicp-learning-ui-2026-10-31/notes.png)を参照。
[本文](sicp-learning-ui-2026-10-31/reading.png)と帰還後のRGBA hashは一致した。

証跡の[source/binary identityと結果](sicp-learning-ui-2026-10-31/result.json)には、
候補commit、ファイルhash、image hash、テスト結果、元checkoutの4ファイルのhashを保持する。
資格情報を含むnetwork設定・receipt、workspace DB、ファームウェア本体は記録へ含めない。

再現手順：

```sh
sh tools/build-xy-mac.sh
sh tools/build-xy-tab5-preview.sh
python3 tools/xy_learning_test.py -v
python3 tools/xy_reader_test.py -v
python3 tools/xy_workspace_test.py -v
python3 tools/xy_tab5_reader_test.py -v
python3 tools/xy_sicp_test.py -v
python3 tools/native_image_test.py -v
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
sh tools/run-static-analysis.sh
sh tools/build-native.sh device
```

## 残る条件

[PR #99](https://github.com/masanork/nihos/pull/99)は実機確認前のdraftとして作成した。
新しい演習UIを含む候補の書込み・物理キー・タッチ・表示・stack guardは未検証。
先行する読書実装の実機証跡を、今回の演習の実機成功へ読み替えない。main統合済みとは扱わない。

草稿・メモは画面往復の間のRAM保持に限る。終了・再起動後の再開、保存障害、電源断は対象外。
次は実機でこの往復を確認し、別入力の準備コードと呼び出しを備えた定義用実験、処理系拡張、
永続化へ進む。参考値の承認・自動採点も現時点では行わない。
