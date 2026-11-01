# xy: Schemeで動くplotと評価失敗からの復帰

基準はPR #96のmerge `d287bc9c66f8796aaf7a9ea7ccf893355be11567`。
作業中に入ったhome/readerのPR #92もmerge `0cb0ee4f`まで取り込み、共通描画とC ABIの
現mainに対して検証した。reader modeでは新しいapp helperも評価・callback実行を拒否し、
read-only guardを迂回できないことをC ABI経由で検証する。
独立worktreeで、GPUIの共通app v1へScheme callbackを接続した。
別のVMを増設せず、`c_abi_host`のlive editor VMとrollback境界を使う。
新しいC helperはprototype用で、app v1のrecord layoutは変更していない。

## 実装と上限

- `app/on-frame!`は1引数closureまたは`#f`で置換・解除する。closureとlexical環境を
  GC rootとして保持する。pauseは保持し、stop・評価失敗・cancel・reopenで解除する。
- callbackはrunning中にticksが変化するaccepted eventに対して1回だけ実行する。
  4step catch-upも1回、resetも1回。引数はticks modulo 2^31で、戻り値は捨てる。
  RGB565/BGRA描画には評価の副作用を入れない。
- 通常評価1024step、callback256step、深さ24未満、全体256cell。callback中は64cellを
  予約する。persistent listを成長させてHeapFullを発生させた後、予約領域で復旧用の式を
  読み取り・評価できることを試した。callbackの中断/再開やwall-clock deadlineではない。
- 文書、定義、view、plot設定の変更はlive transactionを共有し、失敗時に戻す。
  その後でcallbackを解除しpause、editor statusに理由を出す。文書更新のないframeでは
  editor画像を作り直さず、view/文書revisionが変わった時だけGPUI paneへ反映する。
- 初期RAM bufferの[例](../../src/app/plot_demo.scm)はSchemeで振幅を変化させる。
  Run / Ctrl-Enter / F5で評価し、Stop / Ctrl-Cで解除・停止する。
  `plot/set!`の振幅・位相・RGB24色と、Canvasの描画は同じ設定を使う。
  sine tableも共有し、実行時FPUを要求しない。
- 普通のCocoa/Tab5のeditor VMはapp capabilityを有効にしない。そこではapp/plot操作は
  `App unavailable`を返す。R7RS libraries/import、proper tail recursionは未実装である。

## 検証

`tools/check-xy-animation.sh`は従来のclock/sessionに加え、live workspace/VMの16件を実行する。
匿名closureのcaptured counterをGCを挟んで更新し、callbackの置換・解除、設定のatomic更新、
budget/Depth/HeapFullと復旧、文書・定義のrollbackを検証した。
RV32 soft-floatの単独ELFを2本linkし、clock/Canvasと実際のScheme callback経路を残した。
これらは実機やエミュレーターでの実行証拠ではない。

Rust headlessでは実C ABIを通じて、例の評価と画素変化、600callbackの継続、pause/resume、
coalesced update、callbackによる文書編集とUndo、未定義名・評価予算超過での停止、
VM/文書/plotのrollback、停止後の再実行・cancel・reopenを検証する。
従来の737,280画素のRGB565/BGRA比較、frame stride/容量・32キーの試験も継続する。
graph初期/movingとlabel PNGは前PRの正本と一致し、editor PNGは新しいScheme例・statusに変わる。

実GPUIウィンドウは`cua_repl`で操作した。Runで振幅が変化するplot、Ctrl-C停止、
Ctrl-Enter/F5再実行を観察した。EditorへTab移動して余分な`)`を挿入し評価すると、
`Invalid syntax`を表示してpauseした。Ctrl-Zで戻し再実行すると`Scheme OK`とrunningへ復帰した。
background起動直後のsynthetic keyは受信していても画像更新を観察できず、paneをクリックして
アクティブ化してからショートカットを確認した。調査用の一時入力ログは候補sourceから除去した。

ReleaseSafe全体、静的解析・6native ELF監査、Clippy、C ABI layoutの結果と候補hashは
[evidence index](evidence/2026-10-31-xy-scheme-animation/index.json)に保持する。
headless PNGはGPUI screenshotではない。実OS focus移動、実機のGC停止時間・frame latency、
WASMアプリ、SQLite保存・IMEのGPUI移行は今回のqualification対象に含めていない。
