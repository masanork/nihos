# GPUI: 共通xy描画と動くグラフの最初の実証

ベースはmain `e1cfd0c`。この変更はGPUI 0.2.2の実ウィンドウに、既存の共通Zig描画を接続する。
SDLは追加していない。新しいホストにアプリ固有のObjective-C/Cocoa描画コードはなく、
GPUIがOSウィンドウを担当し、本文・グラフ・操作ラベルは共通Canvas/Surface/TrueTypeで作る。

## 動作と画素

- xyのRAMバッファを左、動くグラフを右に表示する。
- Spaceで停止/再開、Left/Rightで速度変更、Rで位相をリセットする。
- Tabまたはclickで入力ペインを切り替える。Editor側は文字挿入、左右移動、Backspace、Enter、Undoを共通Documentへ渡す。
- フォーカスを失うとheld入力を解放して停止する。停止中は追加のanimation frameを要求しない。
- 更新時計と曲線生成はGPUIから独立し、時刻は呼出側から渡す。追いつき処理は最大4step。
- 軸と文字の背景を再利用し、完成RGB565からBGRAへ展開してGPUIへ渡す。古いatlas画像は現フレームの後に退役する。

headless snapshot checkは1024×720の全737,280画素をRGB565の独立展開式と照合する。
動き、pause中の画素保持、再開時の非catch-up、held/focus、Undoによる編集前画素復元、
ラベル可視性、容量不足と不正寸法の無書込み拒否を確認する。この検証はGPUIウィンドウを作らない。

## 実ウィンドウで確認した範囲

macOS上で実際のGPUIアプリを起動し、Computer Use経由のキーとclickで確認した。
日本語の本文と2本の曲線、操作ラベルが見え、SpaceでPaused、Rightでspeed 3に変わった。
TabでEditorへ移り、a/b/c入力、Left、Backspace、Ctrl-Zで`abc`とその途中のカーソルが表示された。
その間、停止したグラフは同じ画素を保持した。ResumeボタンをclickするとRunningへ戻り、曲線が再び動いた。
これはMacのウィンドウ確認であり、Tab5実機・物理キーボード・WASMアプリの実行確認ではない。

初期実装ではGPUIの描画phase外から`request_animation_frame`を呼んで停止した。
callbackではnotifyだけ行い、viewのrender phaseから次のframeを要求するように修正した。
このMacではGPUI標準の文字が表示されない現象もあり、フォント名変更でも解消しなかった。
今回のホストでは操作ラベルも共通TrueTypeの完成画像へ統一している。
小さなラベルをeditorのcaret windowへ通すと文字が切れるため、共通font/cache/shaper/compositorを
使う`renderLabel`を分離した。センタリングは文字数推定でなく実際のglyph advanceで行う。

## 検証と境界

Rust 1.98.1、GPUI 0.2.2とCargo.lock、リポジトリ固定Zigを使用した。
単体検証、headless画素照合、Clippy、static analysis、RV32 soft-float standalone linkを実施する。
RV32 probeは共通時計とCanvasのコードを保持してリンクするが、実機上で走らせていない。
メモリ上の比較と実ウィンドウの観察は別の証跡として扱う。

この段階でR7RSの意味論、native入力adapter、通常Tab5画面の動作は変更しない。
Scheme callback、WAMRの通常サービス接続、SDL互換、nativeでのアニメーション性能、
GPUI版のSQLite保存・IME composition・clipboard/selection・任意ペインresizeは後続である。
[次段階の要件](../planning/xy-animation-runtime.md)と[起動手順](../../apps/xy-gpui/README.md)を参照。

[証跡index](evidence/2026-10-31-xy-gpui-animation/index.json)と
[共通コアの結果](evidence/2026-10-31-xy-gpui-animation/result.json)を保持する。
保存したPNGはheadlessの共通フレームであり、GPUIウィンドウのスクリーンショットではない。
