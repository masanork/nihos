# xy Scheme: resumable `length` and SICP Huffman observations

継続 evaluator の `length` を一要素ごとに中断可能にした。残りのリストを GC ルートとして保持し、空リスト、不正な末尾、循環リスト、引数個数、名前の再束縛を確認した。80要素の各中断で GC を強制するホスト試験も実施した。

MIT の SICP コードと演習 XML の Huffman データ、および別途作成した演習解答を使った7観測を、継続 evaluator で比較した。以前の候補 `5fb03538` では7件とも受理判定で拒否された。今回の候補では演習 2.70 の歌詞36語の `length` が `36` を返し、残る6件は受理判定で拒否された。[入力と観測プログラム](evidence/2026-11-04-xy-continuation-length/sicp-huffman-probe.zig)、[変更前](evidence/2026-11-04-xy-continuation-length/sicp-before.log)、[変更後](evidence/2026-11-04-xy-continuation-length/sicp-after.log)。これは演習全体の合格率ではない。木構築で使う `list` の継続評価などが未対応で、全曲符号化が成功したことも示していない。

プローブの `zig test` は観測を出力するためのもので、拒否やエラーもテスト失敗にはしない。MIT ソースアーカイブ SHA-256 は `9ac51401a7e57c497f5d68998942bde4751f612b094b52d7dda17f4ba23a18fd`、演習 XML アーカイブは `02ac17ebbfeabefff177775c2b608fe008a62cb0cfcc34d4e526c83f453c9621`。再実行例（リポジトリルートから）:

```sh
zig test -O ReleaseSafe --dep scheme -Mroot=docs/measurements/evidence/2026-11-04-xy-continuation-length/sicp-huffman-probe.zig --dep view_config -Mscheme=src/xy/scheme_runtime.zig -Mview_config=src/xy/view_config.zig
```

main `1f20e790` 上の候補（Scheme ソース blob `28b6e5ab60b9d8ad25258ef9a86f06910f9ad58f`）の実機向け trace ELF は、SRAM heap が [no-sqld 49,728 B](evidence/2026-11-04-xy-continuation-length/no-sqld-audit.json)、[sqld 52,928 B](evidence/2026-11-04-xy-continuation-length/sqld-audit.json)。下限 49,152 B を維持した。

CPU クロック初期化を省いた RV32 エミュレーター用 ELF の xy 入力から、90要素の `length` を中断・再開して `90` を得た。[no-sqld](evidence/2026-11-04-xy-continuation-length/no-sqld-emu.log)、[sqld](evidence/2026-11-04-xy-continuation-length/sqld-emu.log)、[ELF SHA-256](evidence/2026-11-04-xy-continuation-length/emu-elf-sha256.json)。実機での挙動と性能は未確認。
