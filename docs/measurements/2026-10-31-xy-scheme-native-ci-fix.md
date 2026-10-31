# PR #98: native通常構成のSRAM配置修正

失敗headは`03ef7fca271d37dc4f60e1d5b7719c9ace85b025`。
[Native USB and card service](https://github.com/masanork/nihos/actions/runs/41189726351/job/124504131098)
の`Compile default connected Tab5 OS`で、通常構成のlinkが
`native SRAM heap below 48 KiB`として失敗した。GPUI/Mac/host/graphics qualificationは
成功していたが、SDK不要の6構成はこの通常接続OSの代用ではなかった。
`sh tools/build-native.sh device integer`で同じ失敗をローカル再現した。

## 原因と修正

`pub const sine linksection(...)`を配列値としてindexしたため、Zigが512byteの匿名constantを
`.rodata`へ生成していた。宣言したFlash storageのaddress経由でindexするように変更した。
同じtableを使うCanvas側もaddress経由にした。

さらにLLVMがFlash上のVM関数用switch tableを`.rodata.xy.scheme_runtime.Runtime.*`へ
生成していたため、そのread-only入力sectionを`.flash.xyrodata`へ集めた。
対象はforeground-only VMの定数で、IRQコード・DMA buffer・mutable dataは移していない。
48 KiBのlinker assertionと監査基準は維持した。

失敗前の出力ASMから、`__anon_28110`が512byteのsine tableで`.rodata`にあることを確認した。
このASMを診断用に再assemble/linkしたmapのheapは48,960byteだったが、診断リンク値であり、
正式な失敗ELFのheap値として比較しない。CI/通常ビルド自体はassertで停止し、ELFを生成しない。

## 再発防止と検証

- native監査はVM app handlerがある時、512byteのnamed sine storageがread-only Flashにあり、
  resident rodataへ同じ内容が複製されていないことを要求する。
- native監査の負試験はmissing/wrong size/unaligned/outside Flash/truncated/duplicate SRAM/
  competing symbolを拒否する。42件の監査単体テストを通過した。
- SDK不要の2本のRV32 probeも、実際にconsumerが参照するtable symbolとread-only/non-executable
  `.flash.xyrodata`への配置を検査する。配列値indexへ戻すと早期に検出できる。
- CIの失敗stepと同じ通常OS・drivers-disabled構成をbuild/image auditした。
  通常構成のheapは49,472byte、最低値との差は320byte。sine tableは512byteのFlash storageとして
  監査に記録され、SRAM copyなし。normal FSの検証も通過した。
- 静的解析と6構成のnative audit、clock/session/live VM検証、GPUI headless検証を通過した。
  `editor.png`/`scheme-moving.png`/`scheme-error.png`とheadless resultは前候補と同じbyte列だった。

[source・候補・ログの証跡](evidence/2026-10-31-xy-scheme-native-ci-fix/index.json)を保持する。
これはbuild/監査とhost実行の検証であり、実機へ書き込んでいない。

## 生成manifestのsource binding

最初の修正pushでは、`esp32p4.ld`を参照する`keypad_atlas.json`、`card_read_font.json`、
`card_auto_font.json`のsource hash更新が漏れ、Host quality gatesの回帰テストで検出された。
全payloadのhashが一致し、XYを無効にしたリンカのpreprocess出力が修正前後で同じことを
確認してから、3manifestの当該source hashだけを更新した。
確認値は[manifest refresh](evidence/2026-10-31-xy-scheme-native-ci-fix/manifest-refresh.json)、
再検証は[Python回帰ログ](evidence/2026-10-31-xy-scheme-native-ci-fix/python-regressions.log)に保持する。
