# xy Scheme: recursive bindings and SICP observations

`letrec`, `letrec*` と named `let` を bounded な AST evaluator に追加した。`letrec` は全初期値を評価してから束縛し、`letrec*` は左から順に束縛する。初期化前の束縛への参照・代入は `Unbound` を返す。named `let` の初期値は外側の環境で評価し、ループ本体は既存の末尾呼び出し経路で評価する。保守的な継続 evaluator はこれらの形式を受理せず、同期 evaluator にフォールバックする。ハードウェアの時間制約や R7RS 全体の適合性を保証するものではない。

R7RS の[束縛形式の仕様](https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-6.html)に基づく限定テストで、相互再帰、名前の重複と初期化順序、外側の束縛、エラー後の再利用、初期化中の強制 GC を確認した。既存の R7RS 20 個の限定プローブは 7 一致・13 エラーから **9 一致・11 エラー**になった。[結果](evidence/2026-11-03-xy-recursive-bindings/r7rs-probes.json)。これは準拠率ではない。

既存の SICP 21 グループはホストで再測定し、観測結果に変化はなかった。[比較](evidence/2026-11-03-xy-recursive-bindings/previous-groups.json)。原文 XML の演習 4.8 の named `let` Fibonacci を 7 入力、4.20 の `letrec` 階乗式を 1 入力で実行し、参照処理系の結果と一致した。[原文の式と結果](evidence/2026-11-03-xy-recursive-bindings/current-sicp_recursive_bindings_4_8_4_20.json)。両演習が求めるメタ循環評価器の変換は試していないため、いずれも部分観測である。

356 演習の内訳は、原文の対象式全体を観測したもの 1、部分観測 123、未観測 232。[一覧](evidence/2026-11-03-xy-recursive-bindings/coverage.json)。これは演習の合格率ではない。一覧中の既存 21 グループのファイルは[前回の証跡](evidence/2026-11-02-xy-native-roots/)にあり、今回の再測定と JSON 内容は同一である。再測定条件と対象 runtime は [snapshot](evidence/2026-11-03-xy-recursive-bindings/snapshot.json) を参照。

sqld あり・なしの trace ELF で標準 image audit を通過し、SRAM heap はそれぞれ 52,800 B・49,600 B だった。[sqld](evidence/2026-11-03-xy-recursive-bindings/sqld-audit.json)、[no-sqld](evidence/2026-11-03-xy-recursive-bindings/no-sqld-audit.json)。既存下限 49,152 B は維持するが、no-sqld の余裕は 448 B に限られる。CPU クロック初期化を省いた RV32 エミュレーター用 ELF では、named `let`、`letrec`、`letrec*`、SICP 4.20 の階乗式と後続式の実行を両構成で確認した。ELF の SHA-256 は no-sqld `4e0d174350456d6ad8a6d53d131eae91b8bfe54548d5d1e87665dd1cdb570e5a`、sqld `2f80300bb07de359810af417c98560cfd68d4840f1949da03de2fc159f14da6f`。[no-sqld](evidence/2026-11-03-xy-recursive-bindings/no-sqld-emu.log)、[sqld](evidence/2026-11-03-xy-recursive-bindings/sqld-emu.log)。実 Tab5 では未検証。

準引用、文字、文字列 API、vector、bytevector、promise、`call/cc`、複数値、衛生的マクロ、大整数・超越関数などは残る。内部定義全般の R7RS `letrec*` 相当の意味論も別途検討が必要。
