# OS教科書としてのシラバスとフィットギャップ

調査日: 2026年10月28日。対象は[章順の正本](book.cjs)にある現行二十章と序章・付録、および下記の参照版のソース・測定記録。編集用資料であり、本文への収録や目次変更、カーネル機能の追加を決定するものではない。

## 評価と本書の到達点

現行原稿は、実機を相手にOSを育てる教材として強い。起動、割込みからの復帰、資源の寿命、コア間通知、DMA、保存の成功条件には、コードと失敗例を結び付けた説明がある。一方、OSの基本事項をこの本で初めて学ぶ読者には、個々の実験を位置づける体系がまだ不足する。**二十章を書いたことと、OSの基礎課程を覆ったことは同じではない。**

不足が大きいのは、タスク管理と待ち集合のデータ構造、スケジューリングの方針・指標、同期とデッドロック、アドレス空間と保護、ファイルAPIから媒体上の配置までの構造である。ブートストラップは既存章にかなりの説明があり、全面的な欠落とは評価しない。メモリ管理も割当と回収は厚いが、仮想記憶・保護までを含む領域全体の充足とはしない。

目標は「小さな共有アドレス空間のOSを実装し、その選択を汎用OSと比較して説明できる」教科書とする。汎用OSの重要概念は説明し、nihosの実装範囲は明示する。すべての概念をnihosの製品機能として実装する必要はない。SMPとSQLite WAL・独自ストアの統合は、このプロジェクトの中心課題として残す。

## 比較基準と評価方法

基準は[CS2023最終報告のOperating Systems領域](https://csed.acm.org/wp-content/uploads/2025/11/CS2023-Report.htm)の14知識単位。原理の学習順は[OSTEPの構成](https://pages.cs.wisc.edu/~remzi/OSTEP/)、小さなRISC-V OSでどこまで扱うかは[MIT 6.1810の説明](https://pdos.csail.mit.edu/6.1810/2025/overview.html)と[xv6教科書](https://pdos.csail.mit.edu/6.1810/2025/xv6/book-riscv-rev5.pdf)を照合した。以下のシラバスと優先順位はnihos向けの編集判断であり、公式課程の転載や認定ではない。CS2023の授業時間をページ数や「網羅率」に換算しない。

前提知識は、関数・ポインタ・構造体・ビット演算、配列と連結リスト、基本的な計算量。レジスタ、スタック、ロード／ストア、キャッシュの前提は短い補講を用意する。Zigの習得とOSの学習を同時に要求する箇所には、最小限の型・構文の説明を添える。

本文の充足度は次の意味で使う。用語が一度登場するだけでは「充足」にしない。

| 判定 | 意味 |
| --- | --- |
| 強い | 中心となる概念・仕組みをコードと実験で追える。領域全体の完結を意味しない |
| 部分 | 説明や実例はあるが、構造図・基本アルゴリズム・比較・演習のいずれかが不足 |
| 不足 | 独立した学習単元として追える説明がない、または比較への言及に留まる |
| 選択 | 概要と他方式との境界を必修にし、詳細実装は発展扱いにする |

各単元の合格条件は、①何を抽象化するか、②状態とデータ構造、③一つの操作の実行経路、④守る条件と失敗例、⑤他方式を選ぶ条件、⑥読者自身の追跡・変更演習、の六点を説明できること。コードのテスト合格と、読者の理解の確認は別に行う。

## 基礎シラバスと現行原稿の対応

章番号は調査時点のもの。実装状況は後段の参照版ごとに扱う。「本文を補う」は、既存の実装で説明できる部分と、比較用モデルで教える部分を含む。

| ID | 学習単元・読了時にできること | 現行の主な対応 | 判定と必要な補強 |
| --- | --- | --- | --- |
| S01 | OSの役割、資源の多重化、ポリシーと機構、monolithic／microkernel／unikernelを比較する | 序章、1章 境界、2章 言語 | 部分。実装責務と保護領域を重ねた全体図、主要APIの分類を追加 |
| S02 | resetから最初のタスクまでを追い、ROM・ローダ・CRT・リンカの責任を説明する | 5章 起動 | 強い。ロード先と実行時アドレス、初期化依存順、CPU1解放の一枚図を補う |
| S03 | 例外・割込み・syscall・関数呼出し、mode switchとcontext switchを区別する | 5、6、10章 ABI | 部分。原因→入口→保存→dispatch→復帰の比較表。ecallだけで保護境界が生まれるわけではない |
| S04 | process／thread／task、資源共有、生成・待機・終了・回収を追う | 寿命、管理表、保護、I/O | 部分。PR #76を反映し、実行単位と保護単位、故障後の回収を説明。独立したprocessオブジェクト、複数threadの領域共有、fork/execは未実装 |
| S05 | ready集合、sleep集合、event待ちをデータ構造で表し、操作コストを説明する | 6、7、8章 | 不足。固定配列走査、優先度別FIFO＋bitmap、deadline heapの比較と手動トレース |
| S06 | FCFS、SJF/SRTF、RR、固定優先度、MLFQの仮定と損益を説明する | 6章 指標への導入、7章 公平性 | 部分。到着・実行・I/O待ちの同一入力で応答・待ち・完了時間を計算。全方式のkernel実装は不要 |
| S07 | 飢餓と公平性の違いを説明し、反例を実装へ結びつける | 7章 TLA+と回帰 | 強い。優先度間の公平性と同一優先度内の公平性、環境の進捗仮定を明示 |
| S08 | race、critical section、atomic、spinlock、mutex、semaphore、condition variableを使い分ける | 8章 SPSCと通知 | 部分。SPSCは良い実例だが一般的同期の代用にはならない。条件再検査、sleep中のlock所有、IRQ内で待てない理由を追加 |
| S09 | lost wakeup、deadlock、livelock、priority inversionを区別し、回避策を選ぶ | 8章 待機競合、16章 寿命 | 部分。lost wakeupは具体例あり。資源待ちグラフ、循環待ち、lock順、期限・取消、優先度継承／上限を補う |
| S10 | SMPでCPUごとの状態、公開順序、通知、cache/DMAの責任を追う | 8、11、13、16章 | 強い。acquire/releaseのhappens-before図、割込み禁止は他CPUへの排他にならないこと、CPU間可視性とDMA整合性の違いを補う |
| S11 | 物理メモリ配置、stack／heap／static、arena／buddy／size class、断片化を説明する | 4、9、11、12、14章 | 強い。ページ管理・サイズ別poolとの関係、内部／外部断片化、管理情報の予算を一枚図にまとめる |
| S12 | アドレス空間、変換と保護、page table、TLB、page fault、demand pagingと置換の基本を追う | 1、6章の比較、11章 外部mapping | 不足。小さなアドレス変換・TLB・FIFO/LRUの紙上／host演習を追加。Flash/PSRAM mappingとプロセスごとの仮想記憶を区別 |
| S13 | 特権・権限・所有権・隔離、syscall引数の検査、故障の封じ込めを説明する | 境界、保護、割当、ABI、I/O | CPU0のU-mode/PMP、スカラECALL、故障と回収の章を追加。v1.3の実機12ケース×3回とエミュレータの限界を区別。汎用アプリローダ、DMAや他チップ版の隔離は未検証 |
| S14 | MMIO、polling／IRQ、driverの上下層、blocking I/O、DMA、buffer寿命を追う | 8、13、15、16、20章 | 強い。汎用的なread要求の受付→待機→完了→返却を先に示し、個別デバイスへ戻す |
| S15 | ファイル・directory・path・mount・open object・FD・offsetの違いを説明する | 16章 VFS/FatFs、19章 二種類のVFS | 部分。名前解決とopen後の参照、close/unlink、部分I/O、権限・世代の構造図と操作列が不足 |
| S16 | file offsetから媒体blockへ到達し、空き領域とmetadataを更新する経路を追う | 17、18章 COW/store | 部分。superblock相当、directory entry、inode/extent、FAT chain、bitmap/free listを比較。独自storeのobject/page mapだけで一般FS構造を代表させない |
| S17 | cache、writeback、sync、順序、journal／COW／logの復旧条件を説明する | 17、18、19章 | 強い。OS buffer cacheとSQLite page cache、二重cache、媒体の保証範囲を関連づける |
| S18 | error、timeout、cancel、再試行、結果不明、容量不足からの復旧を設計する | 8、9、12、15〜20章 | 強い。各章の失敗を共通の状態機械へ整理。再試行で二重実行しない条件も問う |
| S19 | latency／throughput／jitter／deadline、最悪経路と平均値を区別する | 6、8、13、16章 | 部分。周期仕事と割込み禁止区間の時間線、負荷時の応答測定、priority inversionの数値例を補う。hard real-timeを名乗る根拠は未整備 |
| S20 | 観測の影響と証拠の範囲を示して再現可能な評価をする | 3、7、11、17〜19章、実習付録 | 強い。各単元に短い理解問題と解答の要点を追加。性能・公平性・保存性を別々の判定にする |

### 広いOS課程に対する選択範囲

| 項目 | 現状と本書での扱い |
| --- | --- |
| 仮想マシン・container | 現行は不足。CPU・メモリ・I/Oを仮想化する目的、process隔離との違いを概説。hypervisorやcontainer runtimeの実装は対象外 |
| 高度なFS | 17〜19章が強み。RAID、分散FS、重複排除などは比較・参照先に留め、WAL/checkpoint/GCと故障モデルへ紙幅を使う |
| ネットワーク | 15章で実機の状態と回復を扱う。socketとbuffer・backpressureの概念は説明し、TCP/IP・TLS全体の再実装は課程の前提にしない |
| セキュリティ | 基本の保護・権限・入力検査は必修。認証プロトコルや暗号の証明は別分野。カード通信成功を身元確認・署名検証済みと教えない |
| 社会・倫理・保守 | 序章・言語・カード章に関連記述はあるが体系化不足。ログの個人情報、更新と復旧、EOL、由来とライセンスを短い設計課題にする |
| 言語史・描画・日本語・カード | 2、10、12〜14、20章は独自性を持つ事例。OS基礎の代わりとして数えず、選択読書の経路も用意する |

CS2023の14単位との対応は、役割=S01、原理=S01〜03、並行性=S08〜10、保護=S12〜13、スケジューリング=S05〜07/S19、process=S04、メモリ=S11〜12、device=S14、FS API/実装=S15〜16、高度FS=S17、仮想化=上表、組込み/real-time=S19、耐障害=S18/20、社会/倫理=上表となる。この対応は「説明すべき場所」を示し、現時点での充足宣言ではない。

## 四つの重要領域の具体的な補い方

### タスク管理とスケジューリングのデータ構造

[scheduler](../../src/kernel/scheduler.zig)には固定長`tasks`配列があり、state、priority、generation、runtime、wake tick、event情報を持つ。[task runtime](../../src/arch/riscv32/task_runtime.zig)の`images`が保存frameとstack範囲などを対応づける。PCB/TCBの概念はすでに説明できる。nihosではそれらの役割が複数の型に分かれていることを示す。

ready queueは「必ず連結リストとして存在する構造」ではない。現行方式では`state == ready`の要素の集合を配列走査で扱い、優先度を選んで循環走査する。sleep期限の更新も表を走査する。capacity=N、priority_levels=Pとしたとき、選択と期限走査はO(N)、優先度別cursorの追加領域はO(P)。小さい上限を明示できる端末では妥当な選択であり、教科書らしくするためだけの置換は不要。

| 表現 | 学ぶ操作と費用 | nihosでの判断 |
| --- | --- | --- |
| 固定長表＋state＋循環cursor | 選択O(N)、slot管理、世代、同一優先度の巡回 | まず現物を教材化する |
| 優先度別FIFO＋ready bitmap | enqueue/dequeue、bitmapから優先度選択、二重所属を防ぐ条件 | 比較用。選択費用が問題になったときに検討。bitmap探索の費用は幅と命令に依存 |
| deadline min-heap | sleep登録O(log N)、最短期限参照O(1)、起床・取消の位置管理 | 比較用。現在の小さな表より複雑になる理由も説明 |
| 待ち対象ごとのwait queue | 条件確認と登録、通知、timeout/cancelの競合、所属の一意性 | event bitで十分な場面と、複数待ち手・順序を持つ場面を区別 |

教材は「A/B/Cがready→Bがsleep→Hをwake→Hがblock→Bの期限到来→Aがexit/reap」の各段階で、管理表、current、cursor、保存frameへの参照を読者に更新させる。stateとmembershipが矛盾する例も作る。

参照版に注意する。原稿基準`196b354`は共有cursor、7章の`d9afd649`は優先度別cursorを用いる。修正は、高優先度のwake/blockが挟まっても低優先度の**同順位の仲間同士**を巡回するためのもの。高優先度が常時readyでも全優先度へCPU時間を保証する変更ではない。

方針比較には同じ小さなworkloadを使い、最初の応答時間=最初の実行−到着、turnaround=完了−到着、待ち時間=ready状態の合計、deadline miss=期限超過を別々に計算する。I/O待ち時間をready待ちへ混ぜない。time sliceを短くした効果とcontext switch費用を分ける。

### ブートストラップ

5章はROM→ESP-IDF第2段ローダ→nihos入口、stack/gp、`.data`/`.bss`、CPU1の初期化分担、ecall復帰、ELF検査をすでに扱う。[start.S](../../src/platform/native/start.S)と[linker script](../../src/platform/native/esp32p4.ld)もある。欠けた新章を作るより、次の全体像と演習を足す。

1. resetからscheduler開始までに、「誰が」「何を前提に」「どのメモリを触るか」を並べる。
2. ROMが行う仕事、loaderが配置・mappingする仕事、nihosのCRTとdevice初期化を区別する。ELFのLMA/VMA、ロードsegmentとsectionの違いを小例で追う。
3. trap vector、interrupt stack、timer、shared stateの準備と、割込み許可・CPU1解放の依存関係を示す。
4. `.bss`初期化やstack整列を壊す紙上／隔離した実験を用意し、ELF監査と実行時検査で何が見えるか比較する。

bootloader、更新slot、署名検証とrecoveryの責任境界は概説する。ROMや第2段loaderの自作、汎用UEFI対応を本書完成の条件にはしない。

### メモリ管理と保護

4、9、11、12、14章をつなぎ、物理配置→ページ単位の供給→buddy/size class→C allocator→利用者の寿命という階層を先に示す。arena・buddy・poolはアドレス空間を隔離する機構ではない。

別の基礎単元では、仮想ページ番号＋offset→page table→物理frame、権限検査、TLB hit/miss、page faultを小さな表で追う。TLB missとpage faultを同義にしない。demand paging、working set、FIFO/LRU、thrashingは短い比較と演習にする。これをP4で実装済みとは記述しない。

P4のFlash/PSRAM mappingを、そのままプロセス別ページングとみなさない。PR #76で追加したCPU0の保護タスクでは、対象chip revisionの特権・保護機構、粒度、trap、ROM/MMIO拒否を実装と実機記録で扱う。アドレス変換の導入ではない。PMPはDMAを制限せず、共有bufferや別CPUへの移動の契約も残る。PMPやU-modeがあるという一般論だけで、あらゆる用途の隔離が成立したとはしない。

allocatorのowner検査やhandleの世代は、APIを通る誤用を拒否できる。しかし、引き続きM-mode空間で動く通常タスクが任意アドレスへ書くことを防ぐ境界にはならない。CPU0の保護クラスを追加しても、通常のサービスをすべてU-modeへ移したわけではない。この違いは本文で必修にする。

### ファイルシステムの構造

17〜19章の復旧・COW・page map・SQLiteは発展教材として厚い。その前に、名前、開いた参照、保存形式の三層を分けて説明する必要がある。

```text
アプリのpath / file handle（POSIXとの比較ではFD）
    → root・mount・権限から名前解決
    → open object / backendのfile identity
    → file offsetからextent / FAT chain / object page mapへ
    → block・page I/O → device・媒体
```

POSIXのFD table・open file description・inodeは比較モデルとして示す。nihosのhandle/offset指定APIへ、そのまま同じ構造があると当てはめない。`read_at`なら共有offsetの問題を避ける一方、寿命や権限、部分read/writeは依然必要である。

媒体図には、superblock相当の起点、名前とfile identity、サイズ、データ位置、空き領域の管理を置く。inode＋block pointer、extent、FAT chainと独自storeのroot/page mapを並べ、同じ「名前から20 B読む」操作を追う。最初は読み取り、次に伸長・truncate・unlink、最後に途中で止まった場合へ進む。

VFSは後続版`f02a167`および`7f182b0`に実装がある。mount/handle/principal/rights/世代、FatFs adapter、RPC、通知競合を使って本文を補える。host試験、opt-in nativeリンク、実機でのmount/read、nativeの書込みとsync、物理電断は異なる段階。調査したnative資料は総call-stackと実機のgateを残している。

SQLiteの参照版`6bb2467`はhostのPERSIST journal・単一connectionで、WAL/shared memory/mmapを無効にしている。これはWALとFSの統合完成を示すものではない。一般FSの基礎→通常のjournal契約→共有log/storeの仮説という順に置く。

## nihosに追加・統合する仕事の優先順位

「本に説明がない」「ソースがない」「正常な起動イメージへ未統合」「実機の保証がない」を分ける。以下は着手順の提案であり、この調査ではkernelやfirmwareを変更していない。

| 優先 | 仕事 | 実装／検証の不足と完了条件 |
| --- | --- | --- |
| I0 | 参照版を整合させる | 既存の公平性修正、task runtime、memory、VFSを同一候補で確認する。別branchの成功を合算しない。本文の各実験は引き続き固定版で再現可能にする |
| I1 | CPU別の実行と待ちを観測する教材用計測 | `TaskSnapshot`など既存機構を再利用し、必要なら上限付きtraceへ拡張。ready/wait/選択の理由と時刻を追え、buffer overflowと計測負荷が見えること。snapshot取得の所有CPUと整合性も定義。全タスクを跨ぐ無条件のlockや重いprintfは追加しない |
| I1 | native VFSの一往復を成立させる | 実装を新作せず既存系統を統合。まずmount→open→read→closeと抜去・再挿入、RPC待機・取消、stack guard/paintを同一実機候補で確認。その後に書込み・sync・再起動へ進む |
| I1 | stackとメモリ予算を閉じる | 静的frameの最大値だけで総stack合格としない。間接call・ROM/assembly・割込みを含む未確認経路を残し、実taskの最大使用量とguardを測る。正常系だけでなくOOM、取消、エラー経路も対象 |
| I2 | SQLite update→commit→reboot→readbackとUI/inputの並行動作 | 通常FS adapterで一度成立させ、store経路と比較できる基線を作る。commit遅延、最大UI遅延、RAM/stack、書込み量、GC停止、復旧時間を同一条件で記録。host process再起動と物理電断は別に判定 |
| I2 | WALと共通log/storeの最小統合 | reader世代、commit公開、checkpoint、回収可能条件を先に固定。通常方式との小さな比較で価値を測る。PERSIST PoCの成功からWAL対応を推定せず、SQLiteの契約を満たす接続を別に検証 |
| I3 | 保護probeから利用者向け実行環境への接続 | 最小probeはPR #76で実装し、Tab5 v1.3のwarm resetで確認済み。次は公開するサービス、入力のコピー、資源の貸出し、取消しとDMA静止を定義する。任意バイナリのローダや複数threadのprocess管理は未実装 |
| 条件付 | 新しいready queue／汎用同期primitive | タスク数・走査時間、複数待ち手、lockが必要な共有状態を測ってから選ぶ。mutexを足すなら所有者、IRQ可否、timeout/cancel、優先度逆転まで契約にする。教科書の単語を埋めるための実装にはしない |

I0〜I2は既存成果を実用の一経路に結ぶ仕事が中心。I3やqueueの変更を先に増やして、SMPと永続化の実用的な成果を遅らせない。I2の「媒体への書込み量」は観測できる層を記し、microSD内部FTLの物理書込み・寿命まで推定しない。

## 深入りしない領域と、最低限説明する境界

| 領域 | 説明すること | 初版・当面のnihosで必須にしないこと |
| --- | --- | --- |
| Unixプロセス互換 | process/thread、資源共有、生成・終了、syscallと保護 | fork/exec、signal、完全なPOSIX ABI、dynamic loader一式 |
| 仮想記憶 | page table、TLB、fault、置換、保護と変換の違い | P4へのxv6ページングの機械的移植、swap、COW fork、汎用mmap |
| scheduler | RR・優先度・MLFQ等の比較、飢餓、待ち、real-timeの基本 | 全方針の製品実装、Linux schedulerの追従、NUMAや大規模load balancing |
| 同期 | mutex/CV/semaphore、deadlock、priority inversion、atomicとmemory ordering | primitive全種類、複雑なlock-free collection、汎用futex互換 |
| FS | namespace、handle、配置、空き管理、cache、sync、復旧 | hardlink/symlink/ACL全機能、汎用fsck、RAID/分散FSの実装 |
| 起動 | ROM/loader/CRT、配置、初期化順、更新とrecoveryの境界 | ROMからの全面自作、PC各機種のUEFI/ACPI対応 |
| 通信・暗号・カード | bufferと状態、timeout、再試行、機密の寿命、検証の境界 | TCP/TLS/暗号系の教科書化、未実証の公的credential・相互運用保証 |
| 仮想化 | VM/container/隔離の目的と違い | hypervisor、container platform、分散資源管理 |

「実装しない」は「教えない」を意味しない。特にVM・保護・同期・FS基本構造は、nihosとの差を理解するために本文で扱う。

## 執筆と学習順の変更案

2026年10月28日の図解整備では、既存十章へMermaid由来の15図を追加した。管理表、待機状態、公開順序、buddy、VFS、COW/page mapを可視化し、W0とW1の説明の一部を補強している。同期・仮想記憶・一般FS構造などの独立した基礎単元が完成したという意味ではなく、上の不足判定と以下の執筆課題は残る。

章を開発日順に増やし続けず、基礎を通読する経路と、端末の事例を深掘りする経路を用意する。[言語選択](ja/os-languages.md)・[浮動小数点ABI](ja/floating-and-abi.md)・[日本語フォント](ja/japanese-fonts.md)・[カード](ja/card-terminal.md)は価値があるが、基礎理解の前提として全員に要求しない。

| 順 | 編集作業 | 現行原稿への接続 | 読者の確認課題 |
| --- | --- | --- | --- |
| W0 | 本書全体のkernel/task/service/device/媒体と保護範囲の一枚図 | 序章・1章を補強 | あるwriteの責任者と、誤書込みが及ぶ範囲を指す |
| W1 | 「タスクを管理する表と実行待ち」を新しい基礎単元にする | 6章の後、7章の前。6章と統合する案も可 | 表・current・cursorを一操作ずつ更新し、3方式の待ち時間を算出 |
| W1 | 「共有資源と同期」を新しい基礎単元にする | 8章の前半と接続し、SPSC/IPI/WFIを発展例にする | CVの条件再検査、lost wakeup、2資源のdeadlockとlock順を説明 |
| W1 | 「アドレス空間と保護」を新しい基礎単元にする | 4・9章の割当と11章のmappingを接続 | 変換と権限検査を手計算し、owner検査では防げない書込みを挙げる |
| W1 | 「名前から保存ブロックまで」を新しい基礎単元にする | 16章のVFSを抽出・拡充し、17章より前へ | open/read/close、伸長、unlinkのmetadataとblockの変化を追う |
| W2 | 起動・real-time・error回復を整理する | 5章、6/16章、各事例の共通節 | 初期化依存図、deadline時間線、取消と結果不明の状態機械を作る |
| W2 | 章末課題と解答の要点を揃える | 基礎単元から順に適用 | 実行前の予想、手動trace、条件変更、結果の説明を区別して評価 |
| W3 | 事例を基礎の問いへ戻す | 描画・font・通信・SQLite・カード | 各事例のデータ構造・待ち・保護・永続性を共通の図に位置づける |

新単元は最大四つを候補とするが、章数を先に決めない。既存章の重複を移し、説明→図→短い操作例→実験の順を作る。現時点では`book.cjs`を変更せず、現在の二十章版を比較基準に保つ。

通読の流れは、OSの役割→起動と例外→task/管理表→方針と公平性→同期→SMP→物理メモリと保護/VM比較→I/O→FS構造→復旧とSQLite、を基本とする。言語・FPU・描画・font・通信・カードは対応する基礎の後で選べるようにする。依存関係として必要な用語は、後の選択章だけに置かない。

まずW0/W1で不足を埋め、その後にI0/I1の統合結果を本文へ反映する。仮想記憶や全scheduler方針をnihosへ実装するまで執筆を止める必要はない。

## 参照版と判定の根拠

本文評価は現行Markdownの説明・図・操作例・演習を読んだ判断。keyword検索は所在確認に使い、用語の出現数を網羅率にしない。実装評価は次の固定Git objectを確認した範囲に限る。ローカルmainの`196b354`だけを開発全体の最新状態として扱わない。別系統のソースは`git show <revision>:<path>`で確認できる。

| 参照版 | 確認対象 | 判定に使った点 |
| --- | --- | --- |
| `196b3548ce27f29269e0c9721efba0a01faa65eb` | `src/kernel/scheduler.zig`、`src/arch/riscv32/task_runtime.zig`、`src/kernel/spsc_ring.zig`、`src/platform/native/start.S`、`src/platform/native/esp32p4.ld` | 固定表と実行イメージ、イベント、配列走査、release/acquire、ROM/loaderとnative初期化の境界 |
| `d9afd649d8628aedc484bab0d50496942ffdcb5e` | `src/kernel/scheduler.zig`、`formal/scheduler/README.md`、7章の反例と演習 | 優先度別cursorと有限モデルの対象。共有cursorの基準版と区別 |
| `6bb2467ac14e7cc90b4bc2dde3f45c72360ca420` | `src/storage/checkpoint_service.zig`、`probes/sqlite/store_vfs.c`、store/SQLite測定記録、17〜19章 | hostの永続化経路、PERSISTとWALの区別、page map/GC/予算の範囲 |
| `f02a1674b87fe195c71b549f6cc325661120529d` | 16章が参照するFatFs/VFS/RPCとhost記録 | 本文の固定版。後続native fixtureの成功へ読み替えない |
| `7f182b0a0ba4dd0fd2cd1e6c53a5458b5f5c914d` | `src/fs/vfs.zig`、`docs/measurements/2026-10-28-fatfs-native-link.md`、`docs/measurements/2026-10-28-fatfs-wakeup-host.md` | mount/rights/handleとnative link、通知競合、未解決の総stack・実機gate |

外部比較の参照日は2026年10月28日。上記CS2023最終報告を主基準にし、旧CS2013ページや2024年1月版の授業時間との差を混ぜない。MIT/OSTEPの実装方式をnihosに必須とする判断はしていない。この監査では実機試験・電断試験・kernel回帰試験を新たに実施していない。

## 2026年10月30日: 保護とプロセスモデルの反映

「タスクの実行と、壊せる範囲を分ける」を公平性の後、メモリ配分の前に追加した。W0の全体図、管理イメージの図を改め、PMP範囲、権限を含む復帰、故障後の回収の三図を追加した。S03/S04/S13について実装と観測を結び付けるが、S12のページ表・TLB・demand pagingの不足を解消したとは数えない。版ごとに固定した過去のI/O、PQC、SQLiteの実験を、この保護クラスへ統合した結果とも扱わない。
