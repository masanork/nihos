# xy Scheme: bounded selectors in the sliced evaluator

継続 evaluator の受理判定と実行判定を共通化し、既存の `eq?`・`eqv?` と `cadr`、`caar`、`cdar`、`cddr`、`caddr`、`caadr`、`cdadr`、`cdddr`、`cadddr` を追加した。比較するシンボルも既存の 128 B 上限を持ち、これらの手続きは外部コールバックを呼ばない。`append` や `memq` のような可変長走査は継続 evaluator ではまだ受理しない。局所または大域の再束縛を事前に評価せず、保守的に既存の同期 evaluator へ戻す。

ホストで全追加操作を同期 evaluator と比較し、各中断後に GC を強制した。30 段の非末尾再帰検索では同期 evaluator が `Depth` を返し、継続 evaluator は `31` を返した。型エラー後の復帰、局所・大域の再束縛と副作用の一度だけの実行、可変長手続きの拒否も確認した。

main `dbab125b` を基にした候補で、trace の実機向け ELF 監査は no-sqld 49,728 B、sqld 52,928 B の SRAM heap を確認した。[no-sqld](evidence/2026-11-04-xy-continuation-selectors/no-sqld-audit.json)、[sqld](evidence/2026-11-04-xy-continuation-selectors/sqld-audit.json)。下限は 49,152 B のまま。CPU クロック初期化を省いた RV32 エミュレーター用 ELF では、ミニバッファからの `eq?`・`caar` を含む再帰検索の中断・再開、結果 `31`、`cadddr` の結果を両構成で確認した。[no-sqld](evidence/2026-11-04-xy-continuation-selectors/no-sqld-emu.log)、[sqld](evidence/2026-11-04-xy-continuation-selectors/sqld-emu.log)、[ELF SHA-256](evidence/2026-11-04-xy-continuation-selectors/emu-elf-sha256.json)。実機での挙動や性能は未確認。

main `730cc1f7` に rebase した候補 `0f452fff` の再監査でも、SRAM heap は no-sqld 49,728 B、sqld 52,928 B だった。[no-sqld](evidence/2026-11-04-xy-continuation-selectors/rebased-no-sqld-audit.json)、[sqld](evidence/2026-11-04-xy-continuation-selectors/rebased-sqld-audit.json)。同候補の CPU 初期化を省いた RV32 エミュレーターでも両構成の入力経路が成功した。[no-sqld](evidence/2026-11-04-xy-continuation-selectors/rebased-no-sqld-emu.log)、[sqld](evidence/2026-11-04-xy-continuation-selectors/rebased-sqld-emu.log)、[ELF SHA-256](evidence/2026-11-04-xy-continuation-selectors/rebased-emu-elf-sha256.json)。

SICP 2.70 の全曲符号化はまだ対象外。可変長手続きの分割実行、評価予算と継続フレーム、GC ルートの検討が必要である。別のホスト実験では深い AST 評価中の GC と上限変更によって 84 が得られたが、既存の GC 境界契約のテストに違反したため、本変更には含めていない。
