# xy Scheme: list quasiquotation

リストと対を対象に、`quasiquote`・`unquote`・`unquote-splicing` と省略記法を追加した。入れ子の深さに応じて展開し、splicing によるリストの挿入とドット対の末尾を扱う。ミニバッファはバッククォートやカンマで始まる入力を Scheme 式として扱う。継続 evaluator が受理しない場合は既存の同期 evaluator に戻る。

[R7RS の準引用の記述](https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-6.html)に照らしたリスト・対の有限 11 例は、固定 revision の Chibi と結果が一致した。[差分試験](evidence/2026-11-03-xy-quasiquote/list-differential.json)。入れ子、空の splice、不正な splice、ドット対、エラー後の復帰、および unquote 評価中に GC を強制した場合もホストで確認した。これは準引用の完全準拠を意味しない。vector は未対応であり、構文キーワードの字句的シャドーイング、リテラルの不変性などは別途対応が必要。長い評価や大きな構造には既存の depth・step・heap の上限がある。

既存 20 例の R7RS 限定プローブは、再帰束縛までの 9 一致・11 エラーから 10 一致・10 エラーになった。[結果](evidence/2026-11-03-xy-quasiquote/r7rs-probes.json)。これは準拠率ではない。既存の SICP 22 グループは結果が変わらず、演習 356 問のうち全体観測 1・部分観測 123・未観測 232 のまま。[比較](evidence/2026-11-03-xy-quasiquote/sicp-comparison.json)。演習の合格率ではない。

実機向け trace ELF の image audit は、sqld なし 49,600 B、sqld あり 52,800 B の SRAM heap で通過した。[no-sqld](evidence/2026-11-03-xy-quasiquote/no-sqld-audit.json)、[sqld](evidence/2026-11-03-xy-quasiquote/sqld-audit.json)。下限 49,152 B は維持するが、no-sqld の余裕は 448 B。CPU 初期化を省いた RV32 エミュレーター用 ELF では、ミニバッファからの入力、splicing、ドット対、入れ子と後続評価を両構成で確認した。[no-sqld](evidence/2026-11-03-xy-quasiquote/no-sqld-emu.log)、[sqld](evidence/2026-11-03-xy-quasiquote/sqld-emu.log)。その SHA-256 はそれぞれ `eee892c32e8388ede8c8d3ed2b38c743acc772a0dd5601bb00d63409aece3629`、`689672e893011b4be92db17e12c8931b27159306fd9d976dd0d2ef023c6aa49a`。実 Tab5 の実行・時間計測は未実施。
