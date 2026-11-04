# xy Scheme: resumable `append`

継続 evaluator の `append` を一要素ごとに中断可能にした。未処理の引数、コピー途中のリストの先頭と末尾を GC ルートとして保持する。最後の引数を共有し、それ以外のリストをコピーする従来の振る舞いを維持する。`member`、`length`、`equal?` などは継続 evaluator の対象外で、SICP 2.70 の全曲符号化が通ることを示すものではない。

ホストでは空引数、複数リスト、不正な末尾、最後の引数の共有、コピー元との同一性、再束縛、エラー後の復帰を確認した。80要素を一ステップずつコピーし各中断で GC する試験、および空きセルを減らして増分 GC を複数スライスで実行する試験も通った。

PR #170 の候補 `aa3ec6f0` 上の変更（Scheme ソース blob `e832d46d9161f331bab5e57548d2b0e4b6637070`）で、実機向け trace ELF の SRAM heap は [no-sqld 49,728 B](evidence/2026-11-04-xy-continuation-append/no-sqld-audit.json)、[sqld 52,928 B](evidence/2026-11-04-xy-continuation-append/sqld-audit.json)。下限 49,152 B を維持した。

CPU クロック初期化を省いた RV32 エミュレーター用 ELF では、xy 入力から90要素の `append` を開始し、中断・再開後に期待する結果を得た。[no-sqld](evidence/2026-11-04-xy-continuation-append/no-sqld-emu.log)、[sqld](evidence/2026-11-04-xy-continuation-append/sqld-emu.log)、[ELF SHA-256](evidence/2026-11-04-xy-continuation-append/emu-elf-sha256.json)。実機での挙動と性能は未確認。
