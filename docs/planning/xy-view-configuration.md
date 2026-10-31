# xy の共通描画と S 式の表示設定

Tab5 の通常 xy と ESP-EMU の xy fixture は `render_session.zig` を通り、デスクトップと同じ `viewport_layout`、TrueType reader/rasterizer、`render_adapter`、Surface を使う。固定 ASCII セルへの投影は通常 xy の本文・コマンド行から外した。Tab5 の縦向き framebuffer には借用 Surface を回転して描き、二枚目の framebuffer は確保しない。スプラッシュと旧診断コンソールは既存 Canvas 経路を維持する。

表示設定の正本は `src/xy/view_config.zig`。デフォルトはここに集め、レンダラーは設定値を受け取る。RGB565 と RGBA の色は同じ 24-bit RGB 値から導出する。macOS の下部バーも本文と同じ TrueType 処理に通し、Cocoa の固定フォント・固定パレットを除く。

## 利用方法

```scheme
(view/set! #:font 'gothic #:size 32 #:foreground #x123456)
(view/set! #:direction 'vertical #:background #xfaf6ee)
(view/get #:size)                 ; => 32
(view/get #:font)                 ; => bunsen-gothic
(sys/config-rollback!)            ; 一つ前の表示設定へ戻す
```

Tab5 は Esc のコマンド行で評価できる。長い設定は本文に書き、`eval-buffer` で評価する。[設定例](../../examples/xy/view.scm) はユーザー設定の S 式であり、JSON は使わない。JSON のフォント来歴・イメージ監査・試験証跡は従来どおり残す。

`view/set!` は keyword と値の組を受け取る。全ての型・範囲・画面内に本文が収まる余白を検証してから、一つの設定世代として反映する。不明なキー、範囲外、型違いでは、そのフォームの設定・世代・rollback 履歴を変更しない。値は Scheme の計算結果でもよい。複数フォーム全体の rollback/transaction は保証しない。履歴は直近8回。変更は次の描画へ反映し、文書と undo 履歴は変更しない。

| キー | 値 |
| --- | --- |
| `font` | `'mincho` / `'gothic`（`bunsen-` 接頭辞も可） |
| `size` | 8–96 px。変更時は ruby-size を半分（最小6）に設定 |
| `ruby-size` | 6–48 px |
| `direction` | `'horizontal` / `'vertical` |
| `line-gap`, `ruby-gap` | 0–64 px |
| `margin-x`, `margin-y` | 0–512 px、さらに現在の viewport の寸法で検証 |
| `background`, `foreground`, `ruby-color`, `cursor-color` | RGB、0–`#xffffff` |
| `status-background`, `status-foreground` | RGB、0–`#xffffff` |
| `cursor-width` | 1–8 px |
| `status-padding` | 0–32 px |
| `linear-blend` | `#t` / `#f`、sRGB を仮定した linear-light alpha 合成 |
| `theme` | `'light` / `'dark`。配色と装飾を一括設定後、個別指定で上書き可 |

`theme` はプリセット適用操作であり `view/get` の対象ではない。他の表中のキーは読み戻せる。viewport の寸法、framebuffer、キャッシュ容量、ドライバ所有権はプラットフォーム側の契約であり、ユーザーの表示設定からは変更しない。視覚的な調整では読みやすさ・操作性を優先し、共通 UI の検討はデジタル庁デザインシステムを参照する。

## メモリとフォント供給

Tab5 は CPU0 の所有権付き PSRAM lease にキャッシュ・表示リスト・作業領域を置く。重い組版と TrueType 処理は128KiBの専用スタックで実行し、実行中だけ割込みディスパッチャへ範囲を公開する。schedulerのbootstrap imageの範囲もSPと同時に切り替え、短い切替区間だけMIEを停止する。先頭ガードと boot/IRQ ガードを確認する。割込みを描画全体にわたって停止しない。キャッシュは配列全体を値でコピーせず、参照で走査する。コードと予備フォントは、独立に監査する384KiBの mapped Flash 領域へ配置し、SRAM の48KiB空き基準を維持する。

起動用には Bunsen（CC0）の小さな明朝・ゴシック subset を同梱する。ASCII、かな・句読点と少数の漢字を対象とし、未収録文字は代替字形で示す。来歴と収録 Unicode は `src/xy/fonts/manifest.json`、ライセンスは同ディレクトリの `CC0.txt` に残す。完全な日本語書体・IVS 対応をこの予備フォントだけで満たしたとは扱わない。

`Session.init` は paged `SliceReader` を受け取るため、フォントバイト列は描画処理から分離されている。ただし main の通常起動には、カスタム LFS/FontBLOB から完全なフォントを供給する経路、任意フォント登録の Scheme binding、起動設定の自動ロード・永続化はまだ接続していない。SD の再フォーマットは行わない。

Tab5 の文書は4096 bytes、表示は最大240 graphemeのカーソル周辺窓で、文字サイズと改行に合わせて縮小する。空白の advance と段落境界からカーソルを配置する。長文・複雑なIVS・多数のルビを含む完成した青空文庫 reader の資格試験とは分ける。設定は native の bounded Scheme と desktop の既存 evaluator で共有するが、evaluator 自体を同一実装にしたわけではない。

## 開発・検証

- `zig build test`: 設定の原子性、rollback、GC後の維持、実フォント描画、書体・サイズ・方向の切替。
- `sh tools/build-native.sh device integer`: primary SRAM floor、Flash関数・属性・範囲・イメージ一致を独立監査。
- `python3 tools/run-xy-scratch-smoke.py`: 実際のRV32ゲスト上で同じ描画・入力・Schemeを実行。パネル、DMA、実キーボードの証明にはしない。
- `sh tools/build-xy-mac.sh`: 共通コアと Cocoa host をビルド。`build/xy-mac/xy_mac_host --snapshot build/xy-mac/snapshots` で表示確認。

実機での確認結果は [Tab5検証記録](../measurements/2026-10-31-xy-native-render.md) に残す。入力はシリアル経由であり、実キーボード・光学的画素一致・永続化とは区別する。
