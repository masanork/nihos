# SICP 2.57, 2.63–2.64, 2.67–2.68: symbolic data

演習 2.57 について、MIT 公開 `ch2.scm` の 2.3.2 節の微分器・簡約用構成子と、演習直下の原文 `(deriv '(* x y (+ x 3)) 'x)` を実行した。任意個の項に対応する `augend` と `multiplicand` は、この試験のために自作した解答である。原文の式１例と追加２例は、固定 revision の Chibi と xy のホスト処理系で一致した。[結果](evidence/2026-11-03-sicp-symbolic-deriv/current-sicp_symbolic_deriv_2_57.json)。

MIT コードと XML は既存の固定 SHA-256 を検証し、XML の演習ラベルと MIT コード中の式を確認してから実行する。Chibi の既定環境には `caddr` がないため、両方に等価な補助定義を追加する。初期定義は一度に `begin` の引数にまとめず、複数のトップレベル式として評価する。xy では単一のフォームにおける引数が 16 個に制限されるためである。エラー経路、任意の式、資源上限の外側、Tab5 での実行はこの観測の対象外である。

準引用と文字列を含む main `94bfd96d` で既存の 22 グループを再測定し、前回から差がないことを確認した。[比較](evidence/2026-11-03-sicp-symbolic-deriv/previous-groups.json)、[測定条件](evidence/2026-11-03-sicp-symbolic-deriv/snapshot.json)。この５演習の部分観測を追加した [coverage](evidence/2026-11-03-sicp-symbolic-deriv/coverage.json) は、356 問中、全体観測 1・部分観測 128・未観測 227。これらは実行観測の範囲であり、演習の合格率ではない。

別途、SRAM 配置修正・再帰束縛・準引用・文字列試作を含む統合プレビューの CPU 初期化を省いた no-sqld RV32 ELF で、同じ原文の微分式を xy の入力経路から実行した。ミニバッファは 256 B であり、微分器の定義だけで 383 B になるため、1,408 B のセットアップを scratch に入力して `eval-buffer` を使った。文字ごとの編集履歴が 256 操作に達する前に `forget-undo` を明示的に挟む必要があった。原文の式と結果は一致した。[エミュレーター結果](evidence/2026-11-03-sicp-symbolic-deriv/rv32-emulator.log)、[入力・ELF のハッシュ](evidence/2026-11-03-sicp-symbolic-deriv/rv32-emulator.json)。`tools/sicp_257_native_emu.py --destination <空の作業先>` で検証済みアーカイブから試験用 crate を生成できる。この試験は実 Tab5 の挙動や性能を示すものではない。

演習 2.63・2.64 は、MIT 公開 `ch2.scm` の二分木表現と演習中の `tree->list-1`、`tree->list-2`、`list->tree`、`partial-tree` を使用した。３形状の木を２通りでリスト化した６例と、空・単要素・６要素・往復の４例は、固定 revision の Chibi と xy のホスト処理系で一致した。[結果](evidence/2026-11-03-sicp-symbolic-deriv/current-sicp_set_trees_2_63_2_64.json)。木と入力リストは試験用に用意したものであり、計算量の証明や全入力の正しさを評価していない。これら２演習の RV32 実行は未実施。

演習 2.67 は MIT 公開のハフマン復号器と標本木・ビット列をそのまま使い、`(A D A B B C A)` を得た。空入力など追加２例を含む３例で固定 revision の Chibi と一致した。[結果](evidence/2026-11-03-sicp-symbolic-deriv/current-sicp_huffman_2_67.json)。不正なビットや任意の符号木、RV32 での実行は未確認。

演習 2.68 は MIT 原文の `encode` と標本木に自作の `encode-symbol` を組み合わせ、標本メッセージの復号・再符号化、空入力、追加の記号列の３例で固定 revision の Chibi と一致した。[結果](evidence/2026-11-03-sicp-symbolic-deriv/current-sicp_huffman_2_68.json)。未知の記号に対するエラー経路と RV32 実行は未確認。
