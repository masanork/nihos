# 共通2D描画: 要件と最初の検証

状態: 設計案とホスト用の部分実装。SDL/M5GFX互換、Wasm ABI、文字組版、画面サービス、Tab5実機性能はいずれも未完成。既存カード描画の置換は行っていない。

## 利用者と目的

| 利用者 | 必要なこと | 検証の例 |
|---|---|---|
| XY | テキスト、選択、カーソル、クリップ、スクロール、入力とIME | 日本語を含む行で入力位置と描画位置が対応し、部分更新で画面全体と同じ結果 |
| 青空文庫 | 字形・計測、縦横組み、ルビ、禁則、長文のページ送り | 注記付き固定文書を描き、サイズ変更後も文書位置へ戻る |
| Quake | 連続する画素フレーム、パレット、拡大、入力と音 | 固定フレーム列の画素一致と変換・転送時間、native/Wasm実行時間の比較 |
| Wasm | 扱いやすい版付きAPI、隔離、画素の一括転送 | 不正範囲の拒否、終了時の回収と停止、中断後の復帰 |
| カード画面 | 既存の見た目、制限されたメモリ、消去と安全な切替 | 旧描画と画素比較、各構成のELF容量と実機切替 |

## 境界

1. 描画先はメモリ上のsurface。座標と色、画像、clip、合成を扱う。文字列の意味や端末の所有権は知らない。
2. 表示サービスが画面のlease、描画完了後の公開、DMAとキャッシュ同期、撤収を所有する。アプリがscanoutを直接所有する前提にはしない。
3. テキスト層はフォントと字形、shaping、計測、文字位置を扱う。編集位置・IMEはエディタ、ルビ・縦組み・禁則は組版が担う。Unicode UAX #29/#14とW3C JLReqを参照し、対応版と未対応範囲を示す。
4. nativeとWasmは同じ意味のサービスを使うがABIは別。Wasmのポインタはlinear memoryの範囲検査後に使用し、handleには所有者と世代を持たせる。非同期処理に借用ポインタを残さない。ABIの詳細は実装前に確定する。

## APIの基準とDX

M5Stackの[M5GFX](https://docs.m5stack.com/en/arduino/m5gfx/m5gfx_functions)は矩形、線、clip、フォント、画像などの実用的なAPIを提供し、[M5Canvas](https://docs.m5stack.com/en/arduino/m5gfx/m5gfx_canvas)はメモリ上へ描いてから表示する。よく使う操作名や小さな描画例は参考になるが、C++の互換性を約束しない。

[SDL3 2D](https://wiki.libsdl.org/SDL3/CategoryRender)はホスト移植の参照先。SDLのpresent後のbackbufferは保持を保証しないため、保持されるメモリsurfaceと表示の公開を分ける。[SDL_RenderPresent](https://wiki.libsdl.org/SDL3/SDL_RenderPresent)と同じ名前や呼び出しを使うだけでは互換ではない。SDL adapterは対象関数と挙動をテストした後に互換を宣言する。WASIのみで2D表示が成立すると仮定しない。

開発者には座標・色・描画対象を明示し、妥当な初期値、短い例、戻り値、未対応機能の診断を提供する。直接ピクセル操作とバッチ単位の画像転送を両立し、1画素ごとにWasm境界を越える必要をなくす。型・戻り値・エラー・寿命・スレッド条件を言語bindingごとに文書化する。

## 最初の実装済み契約

`src/graphics/canvas.zig` は借用RGB565LEメモリ上の限定的な実験API。確保、表示、スレッド同期を行わない。元bufferを有効なまま保ち、同時アクセスを呼び出し側が直列化する。`init`は寸法、strideと容量を検査し失敗時null。画素は左上原点でx右、y下、矩形は半開区間。`clipped`は元のclipとの積を持つ独立したviewを返す。`fillRect`はclip外を無視し、幅または高さ0は無操作。内部で広い整数を用いて極端な座標でも加算を溢れさせない。行末paddingは変更しない。塗りは不透明の生RGB565値で、合成や色空間変換はない。

```zig
const canvas = Canvas.init(buffer, width, height, stride) orelse return error.BadSurface;
const content = canvas.clipped(.{ .x = 8, .y = 8, .width = 200, .height = 100 });
content.fillRect(.{ .x = 0, .y = 0, .width = 100, .height = 30 }, 0xffff);
```

既存surfaceのA8合成は別APIであり、このclip付きviewには未接続。塗りの画素単位の同期、damage、自動presentはない。未実装の機能を互換APIとして公開しない。

## 後続の必須設計と受入条件

- 線、画像転送、A8マスク、パレット画像、重なりコピーの座標・clip・stride・alias・alpha・色空間・丸め・エラーを決め、既存画面と比較する。異なる既存の丸めや背景の意味を黙って変更しない。
- surfaceの所有・借用・変更とpresentの可視時点、保持、damage、失敗、DMA完了、キャンセルを定義する。二重bufferやvsyncの存在は保証しない。
- Wasmの許可とhandle寿命、byte範囲と乗算overflow、資源上限、trap・終了時の回収、同期コピーと非同期の寿命を検査する。SDL2/SDL3、WASI、Emscriptenの互換はそれぞれ独立に評価する。
- 選んだカード画面で現行と全画素比較し、stride/guard、不正入力、極端座標を検査する。既存の消去・DMA退役は変更しない。構成ごとのFlash/SRAM/stackと描画時間を測る。
- ホストでXY相当、ルビ付き文章、indexed frameを走らせ、Tab5で同一候補の表示・入力応答・フレーム時間とメモリを確認する。ホスト一致と実機の可視性・性能は別の証拠として残す。

SDL互換層、文字組版、Wasm runtimeの導入や実機試験は、この文書と最小canvasの実装では完了していない。
