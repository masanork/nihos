# 日本語フォントを載せる予算

小さいASCII字形なら、必要な画素をあらかじめ置いておける。日本語の文章を、文字の大きさや縦横を変えながら描く場合はどうだろうか。大きなフォントを読むbufferも、字形を作る作業領域も、最初から全部予約してよいだろうか。

{{ch:drawing-text}}では文字格子から画面までを追った。この章では、その字形を作る部分をFreeTypeとHarfBuzzへ置き換え、必要なメモリと寿命を調べる。実験はホストと独立したRV32命令実行で行う。nativeの画面へ日本語を出すまでの統合は、測定した予算を持ち帰る次の段階になる。

## 文字列から、字形の並びへ

文字と、画面に描く形は同じものではない。例えば「字」という文字には、フォントや大きさによって異なる形がある。文字列から適切な字形を選び、位置を決め、最後に画素へ変える。それぞれを別の仕事として追おう。

Unicodeの文字を順番にbitmapへ変えるだけでは、フォントが持つ置換や位置調整を利用できない。HarfBuzzは文字列とフォント、方向、OpenTypeの設定などを受け、glyph番号、advance、offsetを持つ並びへ変える。これがshapingである。

FreeTypeはフォントのglyphを読み、サイズと描画方針に合わせて輪郭を処理し、画素の濃さを表すmaskへ変える。そのmaskを色と合成すれば、{{ch:drawing-text}}の画素側へつなげられる。

{{figure:font-text-pipeline}}

この並びができても、段落の改行、縦書きのページ配置、ルビの対応、カーソルや選択範囲までできたわけではない。今回の実験は、本文相当の24 pxとルビ相当の12 pxを交互に使い、日本語の横・縦方向のglyphを描く。小さい字形を描いたことを、ルビ組版の完成としない。

## 二つの文章を、開いたままにする

読書中にメモを書くなら、読書側を閉じてから編集側を開く仕組みにはしたくない。一方、FreeTypeのfaceのサイズのような変更可能な状態を、二つのアプリケーションが同時に書き換えると困る。

[実験の構成](git:9e784cf9cde6bd19abb1cf205528ff3b086faaf5:probes/graphics/README.md)では、一つの直列化したworkerへライブラリ呼出しを集める。二つのsessionは同時に開いておけるが、ライブラリ内部へ同時に入ることはしない。sessionの寿命を重ねることと、二つのCPUで同時に関数を実行することを分ける。

アプリケーションから見えるフォントの設定は、sourceの版、face、pixel size、OpenType機能、hinting方針を識別する。一方、worker内の変更可能なfaceは非公開にする。本文と小文字の描画でsizeを切り替えても、別の利用者が途中の状態を観測しない契約にする。

同じglyph番号でも、sizeやhintingを変えると位置と画素が変わり得る。将来cacheを置くときも、どの設定に対する結果かをkeyへ含める必要がある。

## 誰のメモリが、いつまで残るか

FreeTypeのfaceとsource cacheはclientごとに持ち、sessionを閉じるとlibrary objectを破棄してから領域を返す。HarfBuzzにはfaceやfontを閉じても残るprocess寿命の状態があるため、最初のclientの所有物にはせず、serviceの所有物とする。

固定したBIZ UDゴシックと明朝の[ホスト実験](git:9e784cf9cde6bd19abb1cf205528ff3b086faaf5:docs/measurements/2026-10-27-graphics-extent-groups.json)では、貸出しbackingは次のように変化した。

| 状態 | backing要求量 |
| --- | ---: |
| 初回利用前 | 0 |
| 一つのsessionで描画後 | 640 KiB |
| 二つのsessionの通常peak | 1,280 KiB |
| 確保失敗を試す処理列のpeak | 1,664 KiB |
| 二つ目を閉じた後 | 640 KiB |
| 両方を閉じた後 | 64 KiB |

最後の64 KiBには、この処理列で1,415 Bの生きた共有状態が残る。すべてを返せたと報告してはいけない。また表は、実PSRAMのresident量や、画面を含むアプリケーション全体のpeakではない。割当て管理情報、stack、コード、OSのfile cacheなどを別に数える。

二つ目を閉じた後、一つ目が同じglyphとadvanceを出せることも確認した。空き容量が戻ったことだけでは、残る利用者が壊れていないとは言えないからだ。

## 合計は空いていても、大きい親を取れない

最初のkernel-backedな方式は、task ledgerの少数のentryへ大きい親領域を登録していた。管理は単純だが、使う量が少なくても2 MiBの連続blockを要求する場面があった。

別taskの領域を残す断片化条件では、合計では2 MiBより多く空いていても、最大blockは1 MiBになった。フォントを開くための2 MiBは取れない。{{ch:reusable-memory}}の断片化が、実際のライブラリの入口で現れた例である。

後続のextent groupは、一つの所有権entryに最大32個の領域をまとめ、必要なときに小さく取得する。今回の最大要求は512 KiBで、連続2 MiBを取れない条件でも二つのsessionを描けた。空の領域はbuddyへ返すが、生きたobjectを移動する仕組みではない。少しでも利用中なら、その領域は残る。

taskを閉じると、新しい割当てを止め、一回の`drainOne`で一つずつ子を返す。最後にrootを返し、slot再利用を許す。Cから来た任意のポインタを、そのまま信用してpayload内のheaderを読むのではなく、正規の登録情報と照合する。

この方式も、任意の断片化や任意のフォントで開ける保証ではない。必要な最大block、管理枠、割当上限を、実際のworkloadで調べる方法として読む。

## 空きバイト数のほかに、管理枠がある

allocatorは、どのポインタがどの所有者のものかを記録する。小さい確保がたくさん残れば、byte quotaより先に記録枠が尽きる場合がある。

強制auto-hintを使う処理列では、最大694件の割当て記録が生きていた。256件や512件の配列だけでは、空きバイト数を増やしても足りない。一方、記録枠を1,024件へ増やすと、未使用の間にも固定の管理領域を使う。

検索を毎回配列全体へ広げれば、予備枠を増やしただけで通常の確保も遅くなる。実験では、生きている記録のprefixを走査し、内部の穴を再利用し、末尾の空いた記録を縮める。上限のある線形探索であり、割込み遅延や最悪実行時間の保証ではない。

容量を考えるときは、payloadのbyte数、物理blockの予約量、記録数の上限を、それぞれ独立した資源として扱おう。

## ライブラリの確保失敗が、正しく返らなかった

固定版FreeType 2.14.3のauto-hint経路を調べた際、16 Bの確保を失敗させるとNULL参照へ進む経路を再現した。reverse character mapを作る関数の戻り値を、呼出し側がエラー変数へ入れていなかった。[失敗した実行](git:9e784cf9cde6bd19abb1cf205528ff3b086faaf5:docs/measurements/2026-10-28-graphics-autofit-failure.txt)を残し、取得した固定版へ次のpatchを適用した。

{{snippet:font-map-error}}

確保に失敗したらNULLを返すという割当器の契約だけでは、呼ぶ側まで安全にならない。割当器、library objectの途中破棄、既存clientの描画を一続きで試す必要がある。

二つ目のsessionを開き、描き、閉じる処理列では、547個の確保地点を一つずつ失敗させた。二つ目のbackingが戻ること、一つ目の出力が保たれること、その後に同じ処理を成功させられることを照合した。この547地点の試験と、auto-hintを加えた後続のstack・記録枠の試験は、異なる処理列なので数を混ぜない。

## スタックも、実行して測る

C関数一つのframeサイズが分かっても、呼出しの連なり全体のstack量にはならない。hostとRV32でもABIや最適化が違う。

[RV32の命令実行試験](git:9e784cf9cde6bd19abb1cf205528ff3b086faaf5:docs/measurements/2026-10-28-graphics-hinting-stack.json)は、同じfontと処理列を独立したELFへlinkし、命令の実行中にstack pointerの最小位置を観測する。小さすぎるstackではguardで止め、完了した場合はhostのglyph hashとも比べる。

| 構成 | 観測したstack量 |
| --- | ---: |
| 16 KiB raster pool、通常hinting | 18,160 B |
| 2 KiB raster pool、通常hinting | 3,824 B |
| 2 KiB raster pool、hintingなし | 3,824 B |
| 2 KiB raster pool、強制auto-hint | 16,864 B |

raster poolを小さくしただけで、すべての経路が小さくなるわけではない。auto-hintでは別の深い処理へ入り、16 KiBのstackでも足りなかった。32 KiBは、固定したfixtureが完了したことに基づく、最初のnative worker実験用の候補である。

これはP4実機やESP-EMU上のOSではなく、独立したRV32命令実行の結果である。nativeのfile読取り、割込み、trap frameまで含む上限にはしない。任意のfont、任意のsizeへの保証も、追加の制限や検査が必要になる。

## 一人分のstackを、利用者ごとに予約しない

ライブラリを直列に呼ぶworkerなら、そのstackはservice側へ一つ用意できる。利用者のsessionごとに32 KiBを予約する必要はない。一方、最後のclientを閉じたからといって、動いているworkerのstackを返してはいけない。

[workerの設計](git:9e784cf9cde6bd19abb1cf205528ff3b086faaf5:docs/graphics-font-worker.md)では、最初のnative候補のstackを内部SRAMへ置く。PSRAM stackは、cacheの利用可否、trap、終了と回収の条件を増やすため、この測定だけを根拠に採用しない。

1,024件の管理枠を持つcontrollerはRV32で17,224 B、命令実行fixtureの静的な書込み領域全体は21,689 Bだった。提案する32 KiB stackを足すと54,457 Bになる。これは最終firmwareの増分ではないが、clientのPSRAM量とは別に無視できない固定費用である。

既存の単調増加するSRAM arenaから、再起動のたびに新しいstackを切り出すだけでは回収できない。最初の固定予約と、将来の再利用可能なstack poolを区別する。{{ch:io-lifetime}}の「誰がまだ使っているか」という問いが、service自身の実行場所にも戻ってくる。

## PC上で、片方を閉じても描けるか調べる

```sh
git worktree add --detach ../nihos-book-font \
  9e784cf9cde6bd19abb1cf205528ff3b086faaf5
cd ../nihos-book-font
NIHOS_GRAPHICS_KERNEL_BACKING=1 \
  sh tools/run-graphics-memory-probe.sh
```

CMake、C++17 compiler、Python 3、curlを使う。固定したsourceとfontを取得してhashを検査し、C/C++部分をASan／UBSan、ZigのbridgeをReleaseSafeで実行する。結果は`build/graphics-probe/report.json`へ出る。kernel backingもホストの配列上で動き、実機やserialへは接続しない。

まずsessionを二つ開いた時点、一つ閉じた時点、両方閉じた時点のbackingとglyph hashを探そう。演習では、共有状態を最初のclientへ割り当てたと仮定し、どの順序でcloseすると何が残るかを図にする。

RV32のstack比較は、固定toolchainと命令実行環境を使う追加実験で、手順は[probeの資料](git:9e784cf9cde6bd19abb1cf205528ff3b086faaf5:probes/graphics/README.md)と同じ版の`tools/run-graphics-rv32-probe.sh`を読む。先に保存済みの結果で、guardに止められた実行と完了した実行を区別してみよう。

日本語を描く予算は、font fileのサイズだけでは決まらない。共有状態、利用者ごとの寿命、断片化、管理枠、stack、hintingの方針を揃えると、nativeへ持ち込む前に確かめることが見えてくる。
