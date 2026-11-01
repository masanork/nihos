# GPUI共通アプリAPI v1

PR #93のmerge `8aa2f0d0f880b92ef019b170057e0b41643442e4`から独立worktreeで作業した。
GPUIのイベントと完成画像の受渡しをnative v1契約へ移し、旧unversioned animation exportを
削除した。共通Canvas/TrueTypeの画素、既存Cocoa版、Schemeの意味論は変更していない。

## 契約と境界

[`nihos_app.h`](../../include/nihos_app.h)と[`protocol.zig`](../../src/app/protocol.zig)が契約、
[`plot_app.zig`](../../src/app/plot_app.zig)がplotアプリの更新・入力・終了の実装を持つ。
`gpui_host.zig`が既存xyとCanvasへ接続し、Rustは同期foreground ownerとして呼び出す。
32個の論理キーとpress/release/heldを保持し、plot制御には0..3を使う。
入力edgeは最後に受理したeventだけに対応し、renderで消費しない。

不明version、size不一致、reserved/value、未知kind、範囲外key、geometry/stride/format/pane、
不足capacity・metadata size・nullは処理前に拒否する。C pointerの有効性・alignmentと
非重複はnative callerの前提であり、任意pointerを検証できる安全なFFIという意味ではない。
構造体size不一致の試験も、実体は有効な完全構造体を渡した負試験である。

frame上限は240..1280×180..720、stride 8192byte、最大5,898,240byte。
RGB565LE/BGRA8の両方を同じcanonical frameから返す。行末paddingと超過領域は書かない。
呼出側がバッファを所有し、render後に破棄・再使用できる。GPUIが保持する画像は別copyで、
atlas退役は従来通り次frameで行う。generationはsession/pane内だけの比較に使う。

focus喪失とcancel時は更新せずにheldと端数時刻を捨て、pauseする。focus復帰は再開しない。
cancelは冪等で、以後のevent/frame/editor操作を拒否し、openでのみ新しいsessionへ移る。
GPUIはapp quitとCore dropでcancelし、既に予約されたframe callbackもstoppedを見て終了する。
openはRAM editorも初期化するので、保存済みworkspaceの復帰を意味しない。

## 検証

- `sh tools/check-xy-animation.sh`: 時計3件とsession/protocolを含む6件を実行。
  C11でrecord size/offsetを検査し、同じrecordと更新モデルをRV32 soft-floatで単独link。
- Rust headless: version/size/値の拒否、state/metadata/buffer保護、32番目のkeyのedge、
  inactive入力、cancel後の停止と再open、frame lifetime、両pane×両formatの奇数paddingを検査。
  従来の737,280画素のRGB565/BGRA全比較、pause/resume、編集Undoも継続。
- PR #93の`initial.png`, `moving.png`, `editor.png`, `label.png`と、新API経由のPNGが
  全てバイト単位で一致した。対応する正本は前回のevidenceディレクトリに保持する。
- `zig build test -Doptimize=ReleaseSafe -j4 --summary all`、静的解析、Clippyを実行。
  結果と候補のhashは[evidence index](evidence/2026-10-31-xy-app-protocol/index.json)を参照。
- 実GPUIウィンドウで日本語と動くplot、Space停止、Rightでspeed 3、TabでEditorへ切替、
  `abc`入力→Backspace→Ctrl-Zで`abc`復元、Resumeボタンによる再開を観察。
  Cmd-Qでプロセス終了し、再起動後にspeed 2・RAM editor初期状態へ戻ることも観察した。
  ウィンドウ操作とpixel exportの試験は別で、headless resultは実window成功を主張しない。

## 残る確認

実OSのactivation変化に伴うfocus喪失/復帰の観察は未確定で、今回はAPIへの明示eventで検証した。
Tab5/エミュレーターでこのアプリを実行した証拠はない。RV32 linkは実行・frame時間・tearingの
検証ではない。Wasm offset検査・trap回収、Scheme callback/GC/cancel、R7RS準拠化、
SQLite保存/IME移行も未実装。実機・SD・firmwareへ変更していない。
