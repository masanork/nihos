# xy Scheme: 4,096 セルと再開可能な評価

この変更は bounded な xy Scheme を拡張する。R7RS-small の完全準拠、SICP 全演習の実行、実 Tab5 での出荷検証を意味しない。

セルを 4,096 個に拡張し、セル内の相互に排他的な text metadata と pair/closure flag を共有する。大きな runtime と継続状態は xy の PSRAM workspace に置き、既存の SRAM heap 下限 49,152 B は変更しない。32-bit 範囲の exact 整数・有理数、binary64 inexact、小数の入出力、比較、丸め、リスト・対の操作、GC 境界などを増やす。必要な値域や引数・source・処理時間は依然有限であり、超過は Scheme エラーとして返す。

native scratch の一部の純粋な式は、保守的 admission の後、明示的な継続フレームで 16 遷移ずつ評価する。未受理の式・named command は従来の同期 evaluator を使う。ここでいう継続は実装上の評価中断であり、Scheme の `call/cc` の実装ではない。desktop の既存の同期評価契約は維持する。評価中の入力は保留し、Ctrl-C は優先してキャンセルする。GC 中のキャンセルは、部分的な sweep・文字列移動を完了した後に ticket と root を解放し、保留入力を再生する。画面には実行中・キャンセル処理中を示す。

GC は mutator を停止したまま最大64作業単位ずつ進め、継続の root と cursor を保持する。評価・再開・UI service は CPU0 に限定し、VM 稼働中の reset・workspace 再開始を拒否する。no-sqld の評価スタックは初回に初期化し、各再開ではガードを検査して再利用する。作業単位は時間や割り当ての厳密な上限ではなく、同期 fallback や開始時処理の応答時間もこの方式では分割されない。

## 検証

- 最新 main 統合後の ReleaseSafe host build は 218/218 ステップ、979/979 テストが通過した（一部 cache を使用）。最新 main 統合後の Python はプレビュー再生成後に 678 テストを通過。[最終 host](evidence/2026-11-03-xy-production/final-zig-summary.log)、[全実行](evidence/2026-11-03-xy-production/host-build.log)、[Python](evidence/2026-11-03-xy-production/rebased-python.log)。
- SICP の 21 グループの host 再測定は直前の snapshot と一致。356 演習のうち 1 問は原文の対象式全体、121 問は有限の一部に観測があり、234 問は未テスト。これは演習の合格率ではない。[比較](evidence/2026-11-03-xy-production/sicp-compare.json)。継続 evaluator を host で一時 instrument した 342 ケース中 34 ケースが継続 evaluator に受理され、全体では 332 一致・10 エラーで、9 ケースの `Depth` が解消した。[差分](evidence/2026-11-03-xy-production/sicp-342.json)。MIT 公開コードの全アーカイブと XML の出典・hash・ライセンスは [NOTICE](../../third_party/sicp-corpus/NOTICE.md) に記載する。
- CPU クロック初期化を省いたエミュレーター用 ELF（no-sqld SHA-256 `98ffca33c5cd7985fd7db588cb94c4a0eb002f1ae8f74261f381a29eca4a0255`、sqld `372123e06137535befcec71c31e2b1ddc3a03341fe459acb5d156dc3bb249eac`）で検証した。エミュレーターでは保持リスト長 3,200 の圧迫下で結果 `21`、回収中のキャンセル、保留入力の再生と後続式 `42` を確認。SICP 1.27 の9ケースも一致。[キャンセル](evidence/2026-11-03-xy-production/rebased-sqld_cancel.log)、[圧迫](evidence/2026-11-03-xy-production/rebased-pressure.log)、[SICP](evidence/2026-11-03-xy-production/rebased-sqld_sicp.log)、[no-sqld キャンセル](evidence/2026-11-03-xy-production/rebased-cancel.log)。CPU1 からの各評価入口と UI service の拒否を正例・旧候補の負例で確認した。[評価入口](evidence/2026-11-03-xy-production/rebased-hart.log)、[旧候補](evidence/2026-11-03-xy-production/hart-negative.log)、[UI](evidence/2026-11-03-xy-production/rebased-service.log)、[UI 旧候補](evidence/2026-11-03-xy-production/service-hart-negative.log)。
- 同じ no-sqld 圧迫例の `nih_xy_resume` は、エミュレーターで再開 2,614 回あたり各 1,412〜46,114 命令。毎回スタックを初期化した旧候補は 197,982〜242,659 命令だった。[再利用](evidence/2026-11-03-xy-production/rebased-pressure.log)、[旧候補](evidence/2026-11-03-xy-production/no-sqld-resume-cost-before.log)。これは呼び出し単位の観測であり、実機の時間や UI 遅延の上限ではない。再開間でガードを破損させる負例は新候補で検出し、旧候補は上書きして続行した。[新候補](evidence/2026-11-03-xy-production/rebased-guard.log)、[旧候補](evidence/2026-11-03-xy-production/stack-guard-negative.log)。
- 最新 main `388d14c8` を統合後の実機用 ELF の標準 image audit で、SRAM heap は sqld + camera + network + xy trace 52,672 B、同非 trace 52,928 B、sqld なし trace 49,472 B。[sqld](evidence/2026-11-03-xy-production/sqld-final-audit.json)、[非 trace](evidence/2026-11-03-xy-production/sqld-notrace-final-audit.json)、[no-sqld](evidence/2026-11-03-xy-production/no-sqld-final-audit.json)。最後はフロアまで 320 B のため、構成変更時には再監査が必要。試験的 TCP + sqld の実機向けブートイメージも生成と監査を通り、heap は 53,056 B だった（TCP の実機通信は未検証）。統合前の no-sqld ELF で Flash に移動した加算・除算の観測された直接呼び出し元は xy Flash 内だったが、間接呼び出しの証明ではない。[直接呼び出し](evidence/2026-11-03-xy-production/soft-float-direct-callers.txt)。no-sqld の scratch + 評価スタックは 172,544 B 要求し、allocator は 262,144 B を予約した。[placement](evidence/2026-11-03-xy-production/placement.log)。

## R7RS の残差と境界

小数や対の mutation を含む一部機能は増えたが、20 個の限定的な host probe は 7 一致・13 エラーだった。エラー例には `letrec`、named `let`、準引用、文字、文字列 API、vector、bytevector、promise、`call/cc`、複数値、衛生的マクロ、大整数、超越関数がある。[probe](evidence/2026-11-03-xy-production/r7rs-probes.json)。これは仕様全体の準拠率ではない。入出力 port・library/import、完全な proper tail recursion、Unicode と数値塔の範囲なども別途評価が必要。

UI repaint と GC の全期間、reset・画面切替・他コアからのすべての経路、外部 I/O callback、入力源間の順序、PSRAM 圧迫時の復帰、長時間運用と実機時刻は網羅していない。SSH の非公開入力開始時には保留タッチも拒否する。保留入力は種類別に再生し、異なる入力源間の到着順序は保証しない。実 Tab5 での検証は未実施。
