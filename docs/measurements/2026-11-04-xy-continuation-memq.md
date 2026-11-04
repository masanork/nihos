# xy Scheme: resumable `memq` and `memv`

継続 evaluator で `memq` と `memv` の走査を一要素ごとに中断可能にした。検索対象と残りのリストはフレーム内で GC のルートとして保持する。空リスト、見つかった末尾、不正な末尾、循環リストの制限、名前の再束縛は従来の同期評価と同じ扱いとする。`member` の構造比較と `append` はまだ継続 evaluator の対象外であり、SICP 2.70 の全曲符号化の成功を意味しない。

ホストでは同期評価との結果比較に加え、80 要素の探索を一ステップずつ実行し、各中断で GC を実施した。一時的な検索対象とリスト、型エラーからの復帰、循環リスト、局所的な再束縛も確認した。

main `fca21ccb` 上の候補（Scheme ソース blob `3e0507d769074a95b5fb68dc7c9b9c0b92867ab5`）で、実機向け trace ELF の SRAM heap は [no-sqld 49,728 B](evidence/2026-11-04-xy-continuation-memq/no-sqld-audit.json)、[sqld 52,928 B](evidence/2026-11-04-xy-continuation-memq/sqld-audit.json)。下限 49,152 B を維持した。

CPU クロック初期化を省いた RV32 エミュレーター用 ELF では、xy 入力から 90 要素の `memq` を開始し、中断・再開後に `(target)` を返した。[no-sqld](evidence/2026-11-04-xy-continuation-memq/no-sqld-emu.log)、[sqld](evidence/2026-11-04-xy-continuation-memq/sqld-emu.log)、[ELF SHA-256](evidence/2026-11-04-xy-continuation-memq/emu-elf-sha256.json)。実機での挙動と性能は未確認。
