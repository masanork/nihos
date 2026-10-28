# VFS contract coreのhost検証

2026年10月27日。branch `codex/vfs-host-contract`、base `196b3548ce27f29269e0c9721efba0a01faa65eb`。
デバイスや実FSを使わず、単一ownerが直列に呼ぶ契約coreを検証した。
mainや他の作業branchへの統合、実機の保存・回復、SQLite VFSの実装を示す記録ではない。

## 実装した境界

- [VFS core](../../src/fs/vfs.zig)：固定長mount/object table、principal照合、rootからの相対open、
  read/write/sync/close、通常unmount、抜去による失効、静止後の強制detach。
- [fake backend試験](../../src/fs/vfs_test.zig)：既存fileの名前解決とalias同一性、sparseな64-bit offset、
  部分I/O、error注入、呼出し回数の観測。実FSのparserではない。
- [host testへの登録](../../src/root.zig)：通常の`zig build test`で同じ契約を検査する。

開発profileの参照元は別作業branch `codex/storage-plan-tab5-budget` の `67c991b`、
`docs/planning/tab5-development-profile.json`。当該branch全体をこの実装へ取り込んだものではない。
標準上限をmount 8、open object 32、data-file handle 16、公開I/O 4,096 bytes、
path buffer 512 bytes（NULを除き511 bytes）へ合わせた。
小さい固定tableを使う単体試験も同じcoreをインスタンス化する。

principalは将来の認証済みservice入口から渡す前提で、clientが自己申告したIDを信用するAPIではない。
この段階ではapp FD table、8 client/8 FD per appのadmission、RPC認証・queueは未接続。
32 open objectと16 data-file handleの区別はhostで検査済み。

## 結果

Zig 0.17.0、macOS arm64 host。

| 検査 | 結果 |
| --- | --- |
| `zig build test --summary all` | 121/121 PASS。うちVFS 21件 |
| `zig build test -Doptimize=ReleaseSafe --summary all` | 121/121 PASS |
| ZLint 0.10.0、変更したZig 3 file、deny warnings | error 0、warning 0 |
| `zig fmt --check src/fs src/root.zig` | PASS |
| `zig test src/fs/vfs_test.zig -target riscv32-linux-musl -fno-emit-bin` | compile-only PASS。RV32実行・freestanding動作の証拠ではない |
| `git diff --check` | PASS |

初回の開発profile整合前には既存の`tools/run-static-analysis.sh`も成功し、
既存6種類のnative ELF link/auditまで通過した。VFSはそのnative imageには組み込んでいない。
上表の最終sourceへは変更部分のfmt/ZLint、host両mode、RV32 compile-onlyを再実行した。

21件は、read-only policyと能力の分離、foreign principal、権限昇格拒否、path traversal/
drive prefix/不正UTF-8拒否、日本語・非BMP名、LFN/短い別名/case違いによるwriter排他、
2 GiB/4 GiB境界、overflow/backend上限の事前拒否、EOFと短いread、部分write＋満杯、
write timeoutの結果不明と後続停止、抜去・同slot再mount、open/close/sync失敗、
table満杯、異常なbackend結果、異なるmountの同一数値ID、世代最大値でのslot退役を含む。

## source identity

SHA-256はテストした最終sourceに対するもの。

| file | SHA-256 |
| --- | --- |
| `src/fs/vfs.zig` | `2f399486981569e593b908317f2ee904e977462bb2d55942d701a87421bb66bc` |
| `src/fs/vfs_test.zig` | `b04ca8072293e5fcab9cefc7912d14bc50c20634c12d591538ab6713acdab91b` |
| `src/root.zig` | `28bc23b446f541bbb6e307774a9c9c7f2c8551f0a97317c0d3698530d1085f6c` |

## 残る接続と検証

backend callbackはbufferに触れなくなってから同期的に戻る契約である。
timeout後もDMAが継続するdeviceをこのcoreへ直接接続してよいという意味ではない。
`detachQuiescent`の静止確認とbackend tokenの破棄はtrusted owner側の責任で、実機では未検証。

file作成、truncate、namespace更新、directory走査、managed DB領域、durable replace、
異なる実FS backendの共通dispatch、qualification profileとadmission brokerの接続は後続工程。
既存native storage owner/RPCとの統合では既存入口を置換せず、adapterとして接続・回帰検査する。
FAT/exFAT/littlefsの対応やSQLite永続更新は、本coreのhost合格からは判断しない。
共通ログ方式のcrash modelは別backendのcommit・回復・GCを扱い、このVFSの導入前提にはしない。
