# 本体PIN画面の描画

`src/graphics/card_pin.zig` は、縦720×1280・RGB565の固定画面を描く。
入力は `pin_entry.View` の入力桁数・残り回数・有効状態だけで、
PINやServiceそのものを受け取らない。テンキー領域は入力モデルと共有する。
4桁揃うまで「読み取る」を無効にし、PINの用途を「入力補助用」と表示する。

この画面はホストで描画確認した段階である。実機での可視表示、
タッチとの結合、認証付きカード処理はまだ有効化していない。
残り回数3を固定表示するプレビューはカードに接続せず、PINも受け付けない。

```sh
python3 tools/boot-graphics/preview-card-pin.py
open build/card-pin/preview.html
```

プレビューは実装のZig描画関数を共有ライブラリとして呼ぶ。
0〜4桁と入力無効のPNG、表示状態を切り替えるHTMLを出力する。
短いバッファや不正Viewを描画前に拒否し、行末パディングを維持することを
ホストテストで確認する。RV32の独立オブジェクトへのコンパイルも行うが、
この画面の実機リンク・スキャンアウトの証拠とは区別する。

操作確認画面と合わせた固定文字の25マスクは26,359バイトの4-bit RLEで、ヒープやフォント読込は不要。
起動画面と同じNoto Serif CJK JP Regularを使用する。Copyright 2017–2024 Adobe、
SIL OFL 1.1。[ライセンス](../src/graphics/boot/OFL.txt)と
[固定フォントの出典](../src/graphics/boot/provenance.toml)を参照。
通常ビルドは生成済みデータを使い、Pillowやフォントの取得を要求しない。

再生成は、[起動画面の手順](../src/graphics/boot/README.md)で取得した
SHA-256固定のフォントを指定する。異なるフォントは生成ツールが拒否する。

```sh
python3 tools/boot-graphics/generate-card-pin.py build/boot-font/NotoSerifCJKjp-Regular.otf
.tools/zig-0.17.0/zig fmt src/graphics/card_pin_assets.zig
```

カードへ送信しない実機テンキーの構成は[操作確認デモ](native-keypad-demo.md)を参照。
