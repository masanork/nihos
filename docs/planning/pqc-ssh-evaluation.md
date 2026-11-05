# PQC SSH の評価方針（試験中）

2026-11-03。対象 base `99c7c8f7`、P4 で `mlkem768x25519-sha256` を評価する。既存 C6 Hosted は変更しない。TLS や署名の PQC 化は含まない。

## 判断と根拠

前回の全 SRAM 試験は ML-DSA と ML-KEM の両方を含み、heap 下限 49,152 B に対し 15,232 B 不足した。Flash 配置と PSRAM アリーナを使った別のヘッドレス試験では ML-KEM 操作を実行できた。通常構成の ML-KEM API 入口保持試験は ML-DSA も含み、実ワーカーなしで heap span 58,112 B。8,192 B の試験スタックを単純に引くと残りは下限より 768 B だけ多い。Flash の実行領域余りは 302 B。これは SSH を含む現行候補の測定ではなく、余裕の証明でもない。

今回はクライアント側の ML-KEM-768 鍵生成とデカプセル化のみを調べ、ML-DSA と encapsulation は必要なければリンクしない。コードを Flash、作業領域を PSRAM に置く選択肢もある。ただし最適化と配置による削減量、SSH の状態・バッファ、実際のワーカー、スタック、現在の main の増分は未測定である。下限を下げず、最終 ELF の配置と SRAM コピーも監査する。

C6 案は工場 Hosted に KEM オフロード API がなく、C6 ファーム、復旧経路、無線認証との関係の確認が必要。C6 の Wi-Fi とメモリを競合させることになり、既存 P4 SSH も結局必要となる。よってまず P4 で試し、C6 は採用しない。C6 の容量不足を測定で証明したわけではない。

## 実験ゲート

1. RFC 10042 の固定長・エンコード・ハッシュを独立に検査し、鍵交換を OpenSSH と相互接続する。ホスト鍵 pin の不一致や不正長で失敗し、暗黙の古典方式へのダウングレードを成功と数えない。
2. 選択した ML-KEM 実装の keygen/decaps と実ワーカーを SSH と共に通常 P4 イメージへリンクし、PQC 無効対照と比較。heap floor、Flash/PSRAM、スタック、秘密の寿命とゼロ化を実測・監査する。PSRAM 不在・割当失敗・キャンセルは fail closed。
3. エミュレータで処理と UI 共存を確認し、実機では候補を特定して従来方式と鍵交換時間、メモリ、分割転送、再接続、UI 応答を比較する。信頼できる乱数・鍵保管と host pin は別途検証する。

## ホスト相互接続の結果

`NIHOS_SSH_HYBRID_HOST_PROBE=1` の手動 KEX 試験は、実際の OpenSSH に `mlkem768x25519-sha256` のみを提案し、ホスト鍵 pin、公開鍵認証、対話 PTY まで通った。同一応答について誤 pin、切り詰め、暗号文の変更を拒否した。対照の従来方式試験も通過。コマンドは `ZIG=/path/to/zig NIHOS_SSH_HYBRID_HOST_PROBE=1 python3 tools/ssh_openssh_probe.py`。SSH メッセージは既存の packet transport を通り、ホストの TCP ソケットへ分割して送受信している。

加えて、固定した `mlkem-native` `e0e0ae95765f4c48585dc8cdaa0656d4eda46a06` と試験用アリーナでも同じ相互接続・異常系が通った。ホスト上のアリーナカーソル最大は **19,232 B**。これは割当てを再利用しない試験アリーナの値で、スタック、鍵、SSH 状態や P4 の PSRAM 総消費を含まない。空のアリーナで鍵生成・復号が失敗し、内部割当ての残存がないことも確認した。ソースは固定 commit の tarball を SHA-256 `b9f225b455ef268d2469aee26bdd6f6e47e7b24762849bf180074b79ed2db1c4` で照合し、リポジトリには取り込まない。

これはホスト限定の実験で、OS 乱数と一時的な認証鍵を使う。`ssh_hybrid_host_probe.zig` は通常 SSH の negotiation や native service に接続していない。C ブリッジとアリーナは単一呼出し専用で、製品用の所有権・並行性・乱数・秘密消去を提供しない。以前の Zig 版 RV32 ラッパー測定では、keygen の入口フレームが 61,472 B、decaps は入口と一つの呼出先だけで 73,568 B あり、P4 の 8 KiB 試験スタックに収まらない。

## 2026-11-03 の P4 予算調査

`NIHOS_NATIVE_EXPERIMENTAL_TCP=1` の現行 device 構成で、PQC なしの対照がビルド・イメージ監査を通過した。base `99c7c8f7`、ELF SHA-256 `ca3a351668093b0d86bf877861980086710e2506b6d2577f1d0e39f0b080fd02`。主 SRAM 静的占有 110,784 B、リンク上の heap 範囲 53,056 B で、49,152 B 下限との差は **3,904 B**。別領域の既存ワーカースタックは 4,096 B × 6。これは動作中の空き容量ではない。8,192 B を主 SRAM に追加するだけなら下限を割る。別のスタック配置や既存スタックの再設計を排除する測定ではない。

同じ C 実装の鍵生成とデカプセル化の両方を残した freestanding RV32 の単独リンクは、実行コード 18,402 B、読み取り専用 2,532 B、writable/NOBITS 0 B（今回の ELF `fbc52c7caa30c5e265a6a32205ba56e92d295e8eb182e20275eede86a440461c`）。実際のアリーナ、スタック、鍵、SSH、OS、配置 padding は含まない。`ZIG=/path/to/zig NIHOS_MLKEM_ARCHIVE=/path/to/archive sh probes/pqc-ssh/rv32-study.sh` で再現できる。

この２入口とアリーナのコードを主 SRAM に保持する変更を加え、同じ P4 対照構成にリンクすると、`native SRAM heap below 48 KiB` で失敗した。下限は変更していない。これは KEM を呼ぶ実ワーカーや状態を入れる前の試験である。再現用の一時変更は [all-sram-study.patch](../../probes/pqc-ssh/all-sram-study.patch) に記録し、実行後に元へ戻した。失敗ログ SHA-256 は `e5b2b9e34f3f0c419b6ef6d0564c558292eccccc459e9f46b192bfd307e07bc7`。追加コードの Flash 配置・キャッシュ停止時の同期・専用スタックは改めて必要であり、この失敗からあらゆる配置が不可能とは言えない。

別の [flash-roots-study.patch](../../probes/pqc-ssh/flash-roots-study.patch) はコードと定数を既存 xy 用 Flash 領域へ配置した。リンクと bin 生成は通り、ELF `e87532c7a2fa49e35ae25210463a24e39eb0ac4e914ce60893cffcf5f57ebe01` では `nih_pqc_ssh_roots` は `0x40060000`、keypair は `0x40062402`、decaps は `0x400624e0`、allocator/free は `0x400646f4` / `0x40064764`。heap は対照と同じ `0x4ff1b0c0..0x4ff28000`（53,056 B）。ただし既存イメージ監査は **`xy linker symbols differ` で失敗**した。これは未承認の配置を含む ELF のリンク証拠のみであり、安全な Flash 実行、SRAM コピーの不在、監査通過、起動や実ワーカーの証拠ではない。修正を加えるなら、個別の配置と Flash/cache-off 呼出し経路を監査し、負の検査と新たな実ワーカー測定が必要。ログ SHA-256 `a2cfe6df60031b4627f341aabae0b58051dab0dc004999ce1766ae949d5e9229`。

後続の [flash-aligned-study.patch](../../probes/pqc-ssh/flash-aligned-study.patch) は 32 B 定数アラインメントを満たすようコード内に 16 B の隙間を設ける。通常監査は追加関数を許可していないため拒否する。一方、実験限定の [監査器](../../probes/pqc-ssh/audit_flash_fixture.py) は前述の通常監査を維持した上で、固定した 28 関数が一意に xy Flash に収まること、定数 `mlk_zetas` と `mlk_KeccakF_RoundConstants` の Flash 上のサイズ、およびそれら 30 個の完全一致バイト列が SRAM 配置セクションに現れないことを確認した。この実験監査は、ELF `6f04e0605de8782d8f1a78ae33afe478e302e9d8244a707d54bdbe45099cb5ba`、bin `bc292e585542e9706e6ec5640a25262fc823c7612d218f943ea80c25397ec10d` と bootloader/manifest に対して通過した。heap は 53,056 B のまま。定数の SRAM コピーと root 名の改変を実 ELF に注入する [負の試験](../../probes/pqc-ssh/audit_flash_fixture_test.py) は拒否された。

この許可一覧は今回の実験コード用に固定したものなので、変更時は更新・再確認を要する。完全一致コピーの検査は秘密情報全般の消去や、異なるコード列・別名での複製を証明しない。呼出し元からの間接分岐、Flash 更新・キャッシュ停止時の両 CPU の停止協調や、PSRAM の耐障害性は監査していない。リンク用 root は実際に呼び出されず、実ワーカーでもない。今回の画像は実機・エミュレータで起動しない。

## 単一所有者の KEM ジョブ試験

[kem_job.c](../../probes/pqc-ssh/kem_job.c) は呼出し側が所有する鍵状態と 32 KiB 以上のアリーナを用い、epoch の進行、一回の復号、取消、retire を扱う試作である。操作は直列、各バッファは互いに重ならないという呼出し側契約であり、乱数生成、並行性の排他、認証、タスク開始、PSRAM 割当てやキャッシュ協調は提供しない。復号は ML-KEM の implicit rejection を含み、その成功だけでは相手の認証を意味しない。復号完了と取消で鍵を CPU 可視範囲で消し、各操作でアリーナを消す。abort による強制中断、コピーされた秘密、キャッシュ書戻しや物理消去は保証しない。

ホストでは C のジョブを OpenSSH とのハイブリッド鍵交換に使用し、host pin、公開鍵認証、対話 PTY と不正応答拒否が通った。独立試験では Zig 実装との照合、世代不一致・重複実行・取消・retire、鍵とアリーナのゼロ化、鍵生成７箇所と復号19箇所の各内部割当て失敗の回収を確認した。`ZIG=/path/to/zig NIHOS_MLKEM_ARCHIVE=/path/to/archive sh probes/pqc-ssh/run-job-test.sh` で再現する。試験用の複製と固定入力を含み、セキュリティ検証や実機性能を示すものではない。

ジョブ関数を含む RV32 単独リンクは実行 19,330 B、読み取り専用 2,852 B。通常 device + experimental TCP の [job-flash-study.patch](../../probes/pqc-ssh/job-flash-study.patch) のリンク用 root に含めると、標準監査は追加関数を拒否し、固定した追加関数を検査する `NIHOS_PQC_JOB_AUDIT=1` 実験監査は通過した。実験 ELF `f6c81c8ee79d7dea8ea72d06652fe360e233137e2507078376eff3efd69d3f18`、bin `4f15a0a8bd81c4d275c1bb1060301fa1f18468e6761e02e852ef0e9d9a0f6873`、heap 53,056 B。root やジョブの状態は実行されず、スタックやアリーナは予約されていない。このリンク試験は PSRAM やスケジューラへの接続、通常監査の通過を意味しない。

## PSRAM を借りた別タスクのエミュレータ試験

`NIHOS_NATIVE_PQC_TASK=1` は整数・headless・`BOOT_TEST=1` のエミュレータ専用で、既存の Wasm 向けピン留め PSRAM スタック貸与・世代付きフレーム検査とタスク回収を使う。固定公開 seed と coins で keygen、encapsulation、decapsulation の一致、古い epoch と２回目の復号の拒否、次ジョブの取消を実行する。これは SSH の接続経路ではなく、同期する単発 fixture である。

ESP-EMU 0.50.0、4 MiB PSRAM、画像監査済み ELF `86693d93c02613f456642aeda1108cfce9316bbd1b4fc56d16430de006043d3b`、bin `7dee2732dc038e6eb6941c14e609458ccf4af0de9c58769559e9f8b83223343e` で成功。64 KiB の貸与スタック上のウォーターマークは 4,400 B、アリーナのカーソル最大は 19,232 B。128 KiB をピン留め要求し、buddy 課金は 262,144 B だった。正常終了後、タスクを reap してから backing 全体の CPU 可視の消去・貸与返却・free の回復、既に retire したフレームの拒否を観測。タスクの trap は７回、そのうち timer は５回だった。この観測は最悪スタックや実 UI の待ち時間を示さない。0 MiB PSRAM では allocation 前に skip して終了した。

同じ ELF と bin にログを紐付ける [checker](../../probes/pqc-ssh/check_task_log.py) と、失敗ステータス・未返却・guard 破損・timer 欠落等の負のテストを追加した。[実行手順](../../probes/pqc-ssh/run-task-emulator.sh)と[ログ](../measurements/evidence/2026-11-03-pqc-task/)を残す。コードは headless 画像の SRAM にあり、上記の通常 device の Flash 配置実験とは異なる。接続、実乱数、秘密の物理消去、強制停止、Flash/cache-off、UI 共存、Tab5 実機は未検証。

## 同じ別タスクでの SSH transcript と host pin

固定の公開試験ベクトルで、同じ P4 エミュレータタスクが C ML-KEM 鍵生成・復号、X25519、RFC 10042 の共有秘密・SSH transcript hash、Ed25519 host key の pin と署名検証を行った。正しい検証を受理し、誤 pin、改変した署名、改変した server transcript を拒否した。試験の seed・秘密鍵・署名はすべて公開データで、実用鍵には使えない。ベクトルは独立した Zig ML-KEM/Ed25519 実装で生成し、`ZIG=/path/to/zig sh probes/pqc-ssh/check-vector.sh` で一致を確認できる。実際の TCP、SSH ネゴシエーション、OpenSSH とのエミュレータ接続は行っていない。

全体を SRAM に置く構成は heap 下限でリンク失敗した。実験用の emulator profile では `ssh_host_key.verify` と SHA-512 round の２関数を Flash の `.flash.pmp` に配置してリンクした。標準監査は追加関数を拒否する。headless emulator 整数 profile に限定した [実験監査](../../probes/pqc-ssh/audit_emulator_ssh.py) は既存の画像・heap・loader 監査に加え、２関数の Flash 範囲と完全一致 SRAM コピー不在を検査する。ELF の関数名改変と SRAM コードコピーを注入する負の試験は拒否された。PMP 領域への配置は試験のみで、PMP の処理と暗号処理に実行上の依存はない。cache-off の安全性や間接呼出しの完全な解析は未検証。

監査した ELF `01c4b4d527c739b841779cf4d6f3fe4c101ab396b34373f30301550002bda7a5`、bin `3ffec3a2238f97c6cdfedf3b7ef0b5cf3a3c5c53fffc89add44e3dbe7110c630` の 4 MiB PSRAM 実行で、stack 観測値 10,064 B、アリーナ 19,232 B、貸与 128 KiB の buddy 課金 262,144 B、timer capture 32 回。heap は 57,152 B で下限を保った。0 MiB PSRAM は処理前に skip。[ログと source witness](../measurements/evidence/2026-11-03-pqc-ssh-auth/) は前項の KEM 単体候補とは別のイメージに紐付く。これらは固定ベクトルと特定の実行に限る観測であり、最悪スタック、UI 応答、物理 PSRAM 消去、実乱数、実ネットワーク、物理 Tab5 の根拠ではない。

## 公開鍵から応答へのタスク間受け渡し

後続 fixture は子タスクが ML-KEM の公開鍵を生成して `waitEvents` で待ち、親が公開鍵を固定ベクトルと照合してから server 応答を共有領域へ書き、世代付き task handle に通知する。子は応答を受けて復号と transcript・host pin を検証し、結果フラグを公開して終了する。親は task を reap した後、旧 handle への通知と旧 stack frame が拒否されることを確認し、pin 全体を消去・返却する。これは固定データでのタスク間ハンドオフであり、SSH パケットの encode/decode、TCP、既存 SSH driver への統合ではない。応答を受け取れない場合の deadline、取消や強制停止はまだ実装されていない。

正常系、暗号文改変、誤 trusted pin を別々のイメージで実行。どちらの不正ケースも `ssh_ok=0` と終了エラーになり、タスク終了後に鍵の CPU 可視消去・pin の返却・stale handle の拒否を観測した。4 MiB の正常系は待機１回、通知１回、stack 10,192 B、アリーナ 19,232 B、PSRAM 課金 262,144 B。正常系イメージの ELF は `48b6e42f44281b180f4064f2c740f90734903dc076db593035f0ad10d6ace09b`、bin は `a42ff80e9148f0fb71d829ac6c46cf7afa04797672fee6b6b4dc5c27dcbd4675`、heap は 57,728 B。0 MiB は処理前に skip。各 ELF・bin とログの識別子は[証拠](../measurements/evidence/2026-11-03-pqc-ssh-exchange/)にある。２つの不正ケースは `NIHOS_MLKEM_ARCHIVE=/path NIHOS_EMU=/path sh probes/pqc-ssh/run-exchange-negative.sh` で再実行できる。前項の同期試験とは別の候補で、試験された否定条件以外や、物理機・運用上の安全性を保証しない。

さらに後続の test-only timeout profile は、応答を渡さず２ scheduler tick 待った親が取消を publish し、世代付き handle へ通知する。子は待機から戻って `nih_kem_cancel` を呼び、鍵の CPU 可視の消去を確認して異常終了する。親は reap 後に pin を消去・返却し、古い handle の通知拒否を確認した。正常・暗号文改変・誤 pin も同じ変更後に再実行。timeout は ELF `ac65d24f8f7a4d6b8492dd2eeaea1531b953482059027d77a587a775594f9438`、bin `ec32f50428d3a4e79f522b5824170fe9211b6e2cf174cae19cf8f2ff9d0110d0`、heap 57,728 B。チェック済みの別候補と[ログ・source witness](../measurements/evidence/2026-11-03-pqc-ssh-timeout/)を記録する。実行中の C 暗号処理の強制停止、通知失敗、応答と取消の競合、実ネットワークの時刻・deadline、通常 SSH への統合は未検証。２ tick の固定値は試験条件であり、実用の timeout を定めるものではない。

PQC と SSH を含む実ワーカーの P4 リンク、エミュレータ、実機は未実施。試験用データから製品セキュリティを主張しない。

参照: [過去の実験報告](../reports/2026-10-29-pqc-implementation-report.md)、[RFC 10042](https://datatracker.ietf.org/doc/rfc10042/)。

## 実 SSH 応答と KEM 受け渡し状態のホスト検証

`ssh_kem_handoff.zig` は公開鍵、暗号文、共有秘密をサイズ制限付きで受け渡す単一所有者の状態機械である。epoch と request の一致、単調時刻と deadline を検査し、期限切れや時刻逆行では取消待ちに移る。取消後も worker の確認まで backing を再利用しない。開始時に worker が所有すると見なすため、投入失敗時も呼出し側が取消と確認を完了させる必要がある。古い結果や取消と競合した結果は採用しないが、その入力バッファの消去は worker 側の責任である。token の一意性、直列呼出し、期限の進行、取消通知と確認は呼出し側の契約であり、この状態機械自身はタスクを停止しない。

実際の OpenSSH とのホスト試験にこの境界を組み込み、鍵生成からサーバ応答の復号、pin と署名の検証、公開鍵認証、対話 PTY まで通した。鍵生成と復号の backend 呼出しはまだホストで同期実行し、試験時刻も固定値である。認証は信頼できる非再入 callback が行い、検証成功前に transport key を公開しない。異常な pin、切り詰め、改変した暗号文の拒否に加え、状態機械のテストで期限切れ、古い token、取消との競合、認証失敗と時刻逆行を確認した。

RV32 ReleaseSafe のコンパイル専用 witness は handoff 全入口を保持した object で実行コード 2,688 B、読み取り専用 624 B、writable/NOBITS 0 B、状態構造体 2,344 B。これはリンク前の object の値であり、firmware の増分、スタック、worker、SSH 状態、実行時のメモリ総量ではない。通常の SSH driver、P4 の worker と実ネットワークにはまだ配線されていない。実乱数、cache-off、実機および製品セキュリティは未検証。

後続の `ssh_hybrid_reply.zig` は SSH の hybrid 応答全体を解析してから暗号文の借用スライスを返す。メッセージ番号、各文字列の境界、server 値の固定長と末尾を検査し、署名フィールドの途中で切れた応答も復号要求前に拒否する。host key と署名の意味・真正性は後段で検証するため、解析の成功は認証を意味しない。入力バッファは署名検証が終わるまで呼出し側が変更せず保持する契約である。全切り詰め位置、巨大な長さ、server 長、余分な末尾、メッセージ番号をテストし、この解析器を使うホスト試験で Zig と mlkem-native の両 backend による OpenSSH 接続を再確認した。P4 の非同期受信バッファの寿命や driver 接続は未検証。

後続の `ssh_hybrid_reply_buffer.zig` は transport の受信 packet を構造検証して最大 2,048 B の所有バッファにコピーし、成功時だけ decoder を release する。2,048 B はこの実験 profile の上限で、より大きい正当な応答を受け付ける一般的 SSH 実装の互換性を示さない。検証中に借用する間は呼出し側がバッファを変更・消去しない単一所有者契約であり、実際のワーカーへの同期や取消処理を提供しない。断片化入力、decoder 解放と transport abort 後の保持、異常・上限超過時に decoder の packet を消費しないこと、消去を host unit test で確認した。実 OpenSSH の hybrid 応答も transport からこの所有バッファへ受け取る経路で、Zig と mlkem-native の両 backend で検証し、従来方式の対照も通った。KEM は依然ホスト内同期実行で、P4 の実ネットワークやメモリ予算は未検証。

`ssh_hybrid_exchange.zig` は応答保持と KEM handoff を結ぶ単一所有者 adapter である。完全な応答を捕捉してから暗号文を提出し、pin・署名の検証 callback が戻った後に応答を消す。未着 packet は待機を続け、期限切れ・時刻逆行・不正応答では fail closed とする。worker がまだ所有中の取消では、応答を消しても取消確認までは worker backing を回収しない。期限の監視と取消通知・worker 自体の停止、結果コピーの消去、callback の非再入性は呼出し側の責任である。host 上の transport と mlkem-native による OpenSSH 実接続でこの adapter を通し、公開鍵認証・PTY と不正応答拒否を確認した。単体試験では応答未着、stale token、受信後 timeout、認証前 timeout と回収条件を確認した。実ワーカー・実時刻・P4 接続を実装したものではない。

## KEM handoff と実スケジューラの固定ベクトル試験

headless P4 エミュレータ試験で、親が `ssh_kem_handoff.zig` を使用し、子が生成した公開鍵を受け取り、固定サーバ暗号文を提出してから子を通知するようにした。子は従来どおり復号と host pin・署名を検証し、公開試験ベクトルの共有秘密と結果を共有領域に置いて終了する。親は子の reap 後に秘密を handoff へ移して共有コピーを消し、**子が実施した検証結果を信頼する** callback で認証を完了する。これは親が独立して署名検証する設計の検証ではない。timeout では親が明示的に abort し、子の協調的 cancel と reap 後に取消確認する。handoff の時刻値は固定で、実 deadline と結び付いていない。

4 MiB PSRAM の正常系は手元の ELF `c19f553c77fea30c9cba8ffaba39984184ddbb246fdeea222a584ebb5723e094` と bin `a468ebeedcb17bd98066478d8cf84c628d4e461a8bf049c588f0c2b4c26fbb3d` で成功。headless profile のリンク上 heap は 53,504 B、前の timeout fixture の 57,728 B と比べ 4,224 B 減り、49,152 B 下限を維持した。子スタック観測 10,192 B、アリーナ 19,232 B、PSRAM 課金 262,144 B。これは親スタックや最悪値を含む実メモリ予算ではない。暗号文改変、誤 pin、timeout は別イメージで拒否・回収を確認し、0 MiB PSRAM では timeout イメージが割当前に skip した。[画像ごとの hash とログ](../measurements/evidence/2026-11-03-pqc-ssh-handoff-task/)を記録する。

固定データ・限定的な試験用画像であり、ネットワーク packet と `ssh_hybrid_exchange.zig` の P4 配線、実乱数、応答と取消の並行競合、通知失敗、実 deadline、cache-off、実機、物理的消去は検証していない。

## scheduler tick を使った応答待ち期限

後続の headless エミュレータ fixture は、handoff の時刻に固定値ではなく `nowTicks()` を渡す。公開鍵を受領した後、timeout 試験では既存期限を現在時刻から２ tick に短縮し、`tick` が `TimedOut` を返したときだけ子へ取消を通知する。子の協調的 cancel と reap の後に取消を確認し、backing を消去・返却する。期限の延長や期限以前への設定は拒否する。正常・暗号文改変・誤 pin・timeout をそれぞれ別イメージで再実行し、timeout の deadline 観測と回収を検証した。PSRAM 0 の正常画像は割当前に skip。２ tick は試験用で、運用に適切な値を示すものではない。鍵生成中や暗号処理中の強制停止、通知失敗、実ネットワークの沈黙や時刻 wrap は実証していない。

正常系 ELF `b7fe6168e74e9c8b3c6c6920d03e91ec921e9b89e3d43d9b1786693c1b7d2870`、bin `c113bae295759d6691bf378386fed9d2b9440b903e8d53f21b566c3611b2205b`、heap 53,120 B、子スタック観測 10,160 B。親の通常スタックは 8,192 B なので、この観測から親自身で同じ暗号処理を安全に行えるとは言えない。host pin の検証は引き続き子が行い、親がその結果を信頼する固定ベクトル試験である。各候補の[ログと hash](../measurements/evidence/2026-11-04-pqc-ssh-tick-deadline/)を記録する。P4 の実ネットワーク接続や実機は未検証。

## SSH 応答 payload からワーカーへの受け渡し

後続の P4 エミュレータ fixture は固定ベクトルから `SSH_MSG_KEX_ECDH_REPLY` の payload を作り、親が `ssh_hybrid_reply.zig` で host key・server 値・署名の境界を検査し、暗号文を KEM handoff に提出して子を通知する。子は同じ payload を再解析し、そこにある host key、server 値と署名で transcript と host pin を検証する。親は受信 payload の末尾を切り詰めた入力が解析で拒否されることを、正常・改変試験の各実行で確認する。これは固定データをメモリに構築する試験であり、SSH packet framing、TCP、実サーバとの鍵交換ではない。

正常、暗号文改変、誤 pin、timeout、署名フィールド改変をそれぞれ別イメージで実行。署名改変は `ssh_ok=0` で拒否され、子の終了後に backing の消去・返却を観測した。0 MiB PSRAM は割当前に skip。正常画像の ELF は `d43ac62d6ecffb348978056e16f9c0ace7889f23b44d28f2552c7ab92d820e63`、bin は `417dc24939e35423ae9811ca8679a197b450583d78fb712999e662dde6dc2d33`。headless profile の heap は 52,096 B で下限との差は 2,944 B、子スタック観測は 10,176 B。親スタックの最大使用量、通常ネットワーク profile の予算、実乱数、実機、実運用でのセキュリティは未検証。個々の候補の[ログと hash](../measurements/evidence/2026-11-04-pqc-ssh-packet-task/)を保存する。

## 平文 SSH frame の分割受信とワーカー

受信側が初回鍵交換の平文パケットだけを扱う `ssh_stream.InitialDecoder` を追加した。既存の decoder と分割受信・境界管理を共有し、暗号化を有効にする操作を拒否する。NEWKEYS 以降に使う decoder への移行は未実装である。ホスト単体試験で通常 decoder との平文結果、断片化、不正 padding、暗号化設定の拒否を比較し、既存の暗号化受信試験と OpenSSH host probe も通った。

P4 の headless fixture は固定 SSH 応答 payload を平文 frame に詰め、元 payload を消してから 13 B ずつ decoder に渡す。受信結果の構造を検査して共有領域へコピーし、子がその内容で KEM 復号、host pin と署名を検証する。不正な packet length と切り詰めた SSH 応答も拒否する。decoder は pinned PSRAM の作業領域に置き、要求サイズは 192 KiB、buddy の課金はこの実行で 262,144 B。正常・暗号文改変・誤 pin・署名改変・協調的 timeout をそれぞれ別イメージで確認し、0 MiB PSRAM の正常画像は割当前に skip した。[各ログと hash](../measurements/evidence/2026-11-04-pqc-ssh-frame-task/)を保存する。

正常画像の ELF `0f85977965351f6da888ca7c01784a5631140bfb70ad6f53d77596a6fb5842ab`、bin `ffa3b55f38e812e29d09c46045c8451bf5ec9785c5092b7623fb4314404ae9f6`、リンク上の heap は 50,304 B で 49,152 B 下限との差は 1,152 B。子スタック観測は 10,176 B。暗号化後も扱う通常 decoder を試験に直接加えたリンクは heap 下限で失敗した。どちらも headless fixture であり、通常 TCP 構成の SRAM 予算ではない。実ネットワーク、実サーバ、実乱数、NEWKEYS 切替、cache-off、実機、物理的な消去は未検証。

## NEWKEYS 境界と暗号化受信の予算

`InitialDecoder.transferAfterNewKeys` は未処理の完全な `SSH_MSG_NEWKEYS` だけを受け付け、新しい通常 decoder に受信 sequence を引き継いで初回 decoder を無効にする。未完成、別メッセージ、使用済みの移行先、sequence 枯渇は拒否する。host key 検証とローカル NEWKEYS の送信完了は呼出し側の責任である。ソケットから NEWKEYS と暗号化パケットが同時に届いた場合、未読バイトを保持して移行先へ渡すこと、sequence を 0 に戻さないこと、MAC 改変の拒否をホスト単体試験で確認した。通常の SSH driver や P4 fixture への接続、P4 での実行はまだない。

`ZIG=/path/to/zig sh probes/pqc-ssh/stream-rv32-study.sh` は RV32 ReleaseSafe の compile-only witness を生成する。この条件の link 前 object は初回 decoder が実行 4,950 B・読み取り専用 1,267 B、暗号化対応 decoder が実行 36,672 B・読み取り専用 1,909 B、いずれも状態構造体は 36,752 B だった。witness が参照する初期化と受信処理を含む object の合計で、関数単位除去後の firmware 増分やスタック、Flash 配置の安全性ではない。２つを別々に確保するなら状態だけで 73,504 B を要する。これらの[識別子と条件](../measurements/evidence/2026-11-04-pqc-ssh-newkeys/summary.json)を保存する。既存の headless fixture で通常 decoder のリンクが heap 下限を割ったため、P4 で実行するにはコード配置とバッファ寿命をさらに設計・監査する必要がある。

## 通常 device + TCP に KEM と暗号化受信コードを保持する配置試験

通常 device + experimental TCP の対照を再ビルドし、監査済み ELF `84f63b26445177578b3c790c946e8f7c6b0ef932a6ec05ef9d3ff65b37e023fc` の主 SRAM 静的占有 110,784 B、リンク上 heap 53,056 B を確認した。試験用の [link patch](../../probes/pqc-ssh/device-stream-link-study.patch) は C の KEM job と暗号化対応 SSH decoder の compile-only witness を既存の xy Flash 領域に保持する。通常画像のコードには適用していない。候補 ELF `f8e5ed467c0647b9417983cc61df80a1e8bed22d216e64f4071cd37d9c53df12`、bin `56296a57ed15d09d3bab3130c9978ec405cd5a7e148aaa4972e4907574f48a9e` はリンクし、静的占有と heap は対照と同じだった。xy Flash のコードは 209,936 B から 249,216 B、rodata は 3,306,844 B から 3,307,660 B に増加した。

標準監査は追加関数を未承認として拒否する。固定した関数名・大きさと object hash を持つ [試験専用監査](../../probes/pqc-ssh/audit_device_stream.py) は既存画像監査を維持し、KEM の完全一致 SRAM コピーを拒否し、decoder の関数と定数について対照から一致バイト列が増えていないことを確認した。SHA-256 の初期状態を含む 112 B は対照にも同数存在するため、追加コピーでないという比較に留まる。KEM と decoder のコードの SRAM コピー、および decoder シンボル欠落を注入する４つの[試験](../../probes/pqc-ssh/audit_device_stream_test.py)も通った。対象は固定 object・固定 baseline・選択した完全一致バイト列であり、異なる表現の重複、呼出し関係、cache-off と両 CPU の同期を証明しない。

これは **関数をリンク用 root で保持しただけ**で、KEM と TCP/SSH をつなぐワーカー、decoder の状態、PSRAM、乱数、スタックは追加していない。標準監査通過、起動、実ネットワーク、Tab5 実機、製品セキュリティを意味しない。ELF と manifest は ignored build ディレクトリに保存し、[候補の hash と条件](../measurements/evidence/2026-11-04-pqc-tcp-stream-placement/summary.json)を残す。再監査には同じ object・baseline・候補に加えて一時 patch を適用したソースと、同じビルドの sqld/FS manifest が必要である。

## Hybrid KEX driver と nihos TCP のホスト相互接続

`ssh_hybrid_handshake.zig` は packet negotiation と host pin・署名検証をホスト専用 ML-KEM backend から分離する。`ssh_hybrid_driver.zig` は transport の送受信、KEM ciphertext の worker への提出、完了、host proof、NEWKEYS、暗号化開始を単一所有者の状態として順序付ける。worker への提出 callback は入力を戻る前にコピーし、再入せず、完了通知前に自身の秘密と結果コピーを消去する契約である。送信失敗や期限切れでは transport を abort するが、worker の停止・取消通知・確認と backing 回収は呼出し側が担う。host proof は現在 `complete` を呼んだ側のスタックで実行するため、P4 で使う前に適切なタスクへの配置が必要。NEWKEYS 待機を含む全体の期限も呼出し側が管理する。

ホスト上の nihos TCP 実装と libslirp 4.8.0 を介し、同 driver が実 OpenSSH と `mlkem768x25519-sha256` を交渉し、mlkem-native の復号結果を別の呼出しで受け取り、公開鍵認証・対話 PTY・TCP FIN まで進んだ。誤 pin は host proof で拒否した。受信を含む host unit test 32 件で、投入失敗、古い token、応答待ち timeout、認証前に NEWKEYS を送らないことを確認した。[ログ・ソース hash・依存 archive hash](../measurements/evidence/2026-11-04-pqc-hybrid-driver/)を残す。試験の復号はホスト上で後続呼出しに分けた同期処理で、並行 worker、P4 scheduler、C6、Tab5 の実行ではない。旧ホスト probe の異常応答試験も再確認している。

## P4 別タスクで hybrid driver の proof を実行

P4 エミュレータ fixture は 320 KiB の pinned PSRAM に driver・transport・受信状態・64 KiB の子スタックを保持し、親が固定応答を解析した後、driver の排他的所有権を子へ渡す。子は復号と既存の fixture 検証の後に、同じ固定応答と復号結果を `Driver.complete` に渡し、別タスクのスタックで driver 自身の host proof と transport key 導出を実行する。親は子を reap し acquire した後に限り結果を検査し、鍵と pin 全体を消去・返却する。fixture は driver を応答待ち状態に直接設定するため、`Driver.step` の全段階、ネットワーク入力や NEWKEYS の実行試験ではない。検証が期限を越えて戻った場合は、後続の `step` が NEWKEYS 送出前に拒否する。

正常、暗号文改変、誤 pin、署名改変、協調的 timeout の各画像をエミュレータで実行し、想定する受理・拒否と回収を確認した。0 MiB PSRAM は割当前に skip。正常 ELF `5c8e983421a66517cde93d0b13e402875f9b7b68492a1fc2e010a0cb6c7020dc`、bin `3361895fa4194436eb604595705259922d966352533021ab21ecd5a955d05675`。headless profile の heap 64,768 B、子スタック観測 10,208 B、KEM arena 19,232 B、PSRAM 課金 524,288 B。in-place 初期化を使う前の別の試行では約 62.8 KiB を観測したため、コピーを省き再測定した。これらは最悪値ではない。fixture の一部コードと定数を Flash に置く実験監査は通り、対象コード・定数の SRAM コピー注入と関数名改変は拒否された。標準配置監査、cache-off 安全性、他の定数の全コピー不在は示さない。

別のホスト試験では親が driver と transport に触れずに待つ間、別スレッドが KEM と `Driver.complete` を実行し、nihos TCP + libslirp 経由で OpenSSH の PQC 鍵交換、公開鍵認証、PTY、FIN を確認した。誤 pin は拒否。これは P4 のネットワーク試験ではない。各候補とログの[識別子](../measurements/evidence/2026-11-04-pqc-driver-worker/summary.json)を保存する。実 TCP に対する P4 側 driver 全段階の接続、C6、実乱数、実機、物理消去は未検証。

後続の P4 fixture では、親が `Driver.dispatchReply` を呼び、driver 自身に応答の捕捉・暗号文コピー・worker 投入・待機状態への移行を行わせる。前項の手動による handoff 状態設定は使わない。平文 frame は `InitialDecoder` で検証するが、その payload を test-only の transport 受信 slot にコピーするため、実 transport の socket 受信や sequence、driver の全 `step` はこの画像では検証していない。子は排他的所有中に同じ driver の `complete` を実行する。正常・暗号文改変・誤 pin・署名改変・協調的 timeout と 0 MiB skip を再確認した。正常 ELF `aeb366bc04773159d0aaed48152731f046450a33001522200337cd33c830c4c7`、bin `a741aa49b8d95dadcec8c8ad008f32ae0ea8851360fb50ed1642e75409936745`、heap 64,768 B、子スタック観測 10,208 B、PSRAM 課金 524,288 B。対象の code・定数の配置検査と SRAM コピー注入の負の試験も通った。[候補別のログと source hash](../measurements/evidence/2026-11-04-pqc-driver-dispatch/)を記録する。host の実 OpenSSH + nihos TCP + 別スレッド試験もこの変更後に再確認した。P4 実ネットワーク・実サーバ・実機や cache-off は依然未検証。

## 識別交換から hybrid KEX までの接続

`ssh_hybrid_connection.zig` は既存の識別交換・socket pump と hybrid driver を一つの接続状態機械にまとめる。KEM 公開鍵は呼出し前にワーカーが生成済みという契約で、識別交換が終わった後に driver を初期化する。P4 向けに状態を既存領域へ直接初期化できる。epoch、単調時刻と全体 deadline を確認し、識別交換前の失敗でも KEM ワーカーを取消確認前に回収しない。worker が driver と transport を排他的に所有している間に親が poll しないこと、取消の通知・停止確認、鍵生成と乱数の提供は呼出し側の契約である。

ホスト上では識別文字列交換から NEWKEYS までをこの接続処理で進め、nihos TCP + libslirp 4.8.0 経由で OpenSSH の `mlkem768x25519-sha256`、公開鍵認証、PTY、FIN が成功。復号と proof は別ホストスレッドで行い、親は終了まで driver・transport に触れない。誤 pin の拒否と 40 件の host test も確認した。[ログと source hash](../measurements/evidence/2026-11-05-pqc-hybrid-connection/)を保存する。KEM keygen はホスト側で接続前に同期実行し、排他は呼出し順序による試験契約である。native Hosted service・P4 scheduler・C6・Tab5 の接続、実乱数、実機は未検証。
