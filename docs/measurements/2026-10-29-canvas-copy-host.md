# RGB565等倍コピー: ホスト測定

既存 `dd6c8b9` の画素ごとのRGB565コピーと、入力・描画先の非重複を検査した後、clip済み領域を行単位でコピーする候補を比較した。どちらも同じCanvasの公開契約を使う。出力を比較し、行末padding・clip・負座標・重なり拒否もホストテストする。

Darwin arm64、Zig 0.17.0、ReleaseFast、720×480 RGB565、毎回同じ入力、連続200フレームを10回、順序を交互に変えた結果:

| 実装 | 中央値 ms/フレーム | 範囲 ms | 出力SHA-256 |
|---|---:|---:|---|
| 既存 | 0.0922 | 0.0893–0.1339 | `80320ac86029606b61d5b57728512a639950cca654e5683f89d160df3ca0a953` |
| 行単位 | 0.0100 | 0.0099–0.0103 | `80320ac86029606b61d5b57728512a639950cca654e5683f89d160df3ca0a953` |

反復するキャッシュ上のホストメモリ転送であり、Tab5、PSRAM、キャッシュ書戻し、DMA、LCDやフレーム同期の速度ではない。スケール転送は含まない。同じ測定条件でスケール時の除算を増分計算に替える別案はホストで遅かったため採用しない。いずれもRV32の優劣を示さない。

同じ固定寸法probeをRV32 freestanding・ReleaseSmallで、`render`をエントリにして保持しcompiler-rtと静的リンクした場合、`size`のtextは既存206 B、行単位302 Bだった。候補には`memcpy`がリンクされている。これは小さな専用probe全体の差であり、実アプリの増分、stack、速度やRAM消費ではない。エントリなしでリンクした先行probeは未使用コードを除去し得るため、この比較には使用していない。

再測定はまず `git show dd6c8b9:src/graphics/canvas.zig` を一時ファイルへ出力する。Zigの `build-lib -dynamic -O ReleaseFast` で `tools/probes/canvas_blit_bench.zig` をroot、各Canvas版を `canvas` module、現行の `src/graphics/surface.zig` を `surface` moduleとして二つの共有ライブラリにする。`python3 tools/canvas_blit_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY` は結果のSHA-256が違えば失敗し、交互順序の中央値と範囲を出す。採用前に実機候補で同等のバッファ・負荷・測定境界を固定して計測する。
