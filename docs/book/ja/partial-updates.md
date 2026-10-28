# 20バイト直すために、何バイト書くか

33 MiBのデータに、一行の短い変更を加えたい。20バイトの変更なのに、保存のたびに全体を書き直すなら、小さな編集にも待ち時間が増える。前章のコピーオンライトを保ちながら、変更しない部分を使い続けられるだろうか。

この章では、正しさを保つために導入した方式の費用を測り、データと所在の表を分けて改善する。比較するのはまずbackendへの読書き要求量である。時間を測る前にも、何を何回運んでいるかを説明できるようになる。

## 小さいbufferと、少ない書込みは違う

大きいデータを丸ごとRAMへ置かず、4 KiBずつ入力して書けば、bufferの大きさを抑えられる。[streaming実装](git:8b1c3c24fae826699829488c0af2834700945a4d:docs/measurements/2026-10-27-store-streaming.md)は入力を分割し、宣言した長さに達してからfinishし、その後にcommitする。入力待ちの間も古い公開世代を読める。

しかし、部分変更の前後を順にコピーする方式では、bufferが小さくても総コピー量はobject全体になる。固定bufferで動くことと、変更量に応じた費用で動くことは別の性質である。

取消しも考える必要がある。streamが途中ならcommitを拒否し、abortやrollbackで書込み中のtokenを失効させる。入力を待っているだけの状態を、保存完了と取り違えない。前章の成功通知の境界は、入力を分けても変わらない。

## データを分けて、所在を表にする

そこで、データを4 KiBのページに分け、論理ページから媒体上のページを引く表、mapを置く。map自体も、一度作ったnodeを変更しない木にする。

{{figure:page-map-sharing}}

図の矢印は参照を示す。旧rootと新rootは、それぞれのleafを経て同じAとCを指す。Bを直すとき、AとCのコピーを作る必要はない。一方、旧rootや読者が残っている間は、旧Bも必要である。

Bの一部を変えるなら、新しいBを作り、mapの変更経路だけをCOWする。AとCは共有できる。新しいrootが永続化するまでは、旧mapも旧Bも残す。

[map実装](git:8b1c3c24fae826699829488c0af2834700945a4d:src/storage/extent_map.zig)のleafは252個のdata page参照を持ち、internal nodeは126個の子参照を持つ。各参照にはCRCがあり、論理的に担当する範囲も検査する。16 GiBの論理長でも最大4段で辿れる構成だが、全mapをRAMへ読み込むわけではない。

データの位置を表にした費用は消えない。nodeを読む回数、CRC、変更時の経路の書込みが加わる。小さいobjectや一度しか書かないデータでは、単純な連続配置のほうが扱いやすい場合もある。

## 既存データを、コピーせずmapへ移す

既存の連続したblobは、`promoteMapped`でmap方式へ変換する。データ自体は移さず、既存の検査情報からページ参照とCRCを作る。33 MiBの試験ではmap 35ページとobjectのleaf・rootを書いた。

これは初回に一度かかる費用であり、以後の20バイト変更の費用へ黙って混ぜたり、存在しないものにしたりしない。変換はまだblockingで、新しいmapを置く連続した空きも必要になる。

`patchMappedPage`は、一つの論理ページ内の範囲を変える。境界をまたぐ変更では、複数ページの変更を同じtransactionに積んで最後にcommitする。長さの伸長やtruncateは、この参照版のmap用APIには含まれない。

## 切り詰めた内容を、再伸長で復活させない

ファイルの末尾を消し、後から同じ長さへ戻したとき、以前のbyteが再び読めたら困る。物理ページが残っていることと、新しい論理範囲でその内容を読んでよいことは異なる。

[後続のresize実装](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:docs/measurements/2026-10-27-store-resize.md)では、未書込みの論理ページを0の参照で表す。読むと0になり、data pageは確保しない。書込みが来たときにだけdataとmapの経路を作る。16 GiBの全域が未書込みのobjectも、4 KiBのmap root一枚で表せた。これは論理長の検査で、その量のdataを転送したという結果ではない。

pageの途中を末尾にするときは、そのpageをCOWし、切り捨てる部分を0にする。旧readerは元のpageを使い続け、新しいviewは消した部分を再伸長しても0を読む。変更はEOF側の経路へ限り、完全なprefixのsubtreeを共有する。

33 MiBと17 Bのobjectを4,109 B縮め、元の長さへ戻す試験では、縮小と伸長にそれぞれ5 page、20,480 Bを書いた。旧rootの退役を含む合計は45,056 Bだった。全objectのコピーは不要だったが、境界のdataとmapを新しくする費用は残る。

この版は媒体形式をversion 5へ進めた。正しいCRCを持つ旧形式でも、無断で読み替えたりformatしたりしない。前半の単純なmapと、伸長を扱う版の違いを、実習の版とともに読む。

## 読者が残っているページを、空きと呼ばない

共有は回収を難しくする。最新世代がB'を使っていても、古いreaderがBを読んでいれば、Bはまだ必要である。dataだけを保護してmap nodeを返すと、そのdataへ辿れなくなる。

GCは、両方の有効なdisk root、作成中のroot、reader snapshotから、map nodeとdata pageを追う。連続blobを読む古いreaderが残っていれば、元のextent全体も保護する。

nodeには参照先の物理範囲を示すsummaryがある。dataとnodeの範囲を分けるのは、dataから遠い位置にあるmap nodeを空きと誤認しないためである。summaryもCRCと内容の再計算で検査する。

[部分更新の負例](git:8b1c3c24fae826699829488c0af2834700945a4d:docs/measurements/2026-10-27-store-extents.md)では、dataの保護を外しても、nodeの保護を外しても、旧readerが壊れた。共有する対象を増やすと、守る参照も増える。GCを単なる「古いものを消す処理」として読むだけでは足りない。

## 改善を、同じ入力で比べる

ホストfileの試験は、33 MiBと17バイトのobjectを作り、ページ境界をまたぐ20バイトを変更する。旧方式とmap方式のbackendへの書込み要求は次のようになった。

| 方式 | 書込み要求 | 4 KiBページ数 |
| --- | ---: | ---: |
| 全objectをコピーする部分変更 | 34,652,160 B | 8,460 |
| mapを共有する部分変更 | 36,864 B | 9 |

要求量の削減は99.89%だった。新旧の全byteを比較し、成功通知後の子process終了、再open、GCと再構築も検査した。mapへの初回変換は別の費用として数えた。

この数字から、SDの保存時間が同じ割合で短くなるとは言えない。小さいwriteの費用、同期の回数、媒体内部の処理、CPUのCRCやmap走査が残る。比較の最初に数えるものを決めると、転送量の改善と待ち時間の改善を混同せずに済む。

## まとめて変えると、何を一度で済ませられるか

20 Bの変更が小さくなっても、SQLの更新のように多数のpageを変える場合がある。一枚ずつAPIを呼ぶたびに同じmapの上位経路を作り直すと、data以外の書込みが増える。

[一括更新](git:6bb2467ac14e7cc90b4bc2dde3f45c72360ca420:docs/measurements/2026-10-27-store-batch.md)は、同じobjectの異なるpageを論理順に最大16件受け取り、共有するancestorを一度だけ書く。件数、順序、重複、範囲を、書き始める前にすべて検査する。

| 16 pageを変更 | 個別APIを16回 | 一括APIを1回 |
| --- | ---: | ---: |
| data page | 16 | 16 |
| map node | 32 | 2 |
| object leaf | 16 | 1 |
| commit root | 1 | 1 |
| 合計 | 65 page | 20 page |

同じ33 MiBのobjectで各pageの1 B、合計16 Bを変えると、要求量は260 KiBから80 KiBへ減った。両方式とも最後のcommitのsyncは二回で、最終dataも同じだった。まとめたことでdata本体が小さくなったのではなく、共通の経路と所在の表を書き直す回数が減っている。

変更が遠く離れたsubtreeへ散れば、共有できる経路は減る。16件という上限も、同期I/O一回の経過時間を保証しない。16 KiBの作業領域はresizeとbatchで順に共用できるが、入力、descriptor、stackも別に必要になる。

## 空き領域を探す処理にも、途中を作る

全体の処理量が減っても、一回の呼出しで長く走れば入力を待たせる。[探索の分割](git:8b1c3c24fae826699829488c0af2834700945a4d:docs/measurements/2026-10-27-store-search-cache.md)では、探索をbegin、step、cancelへ分ける。cursorを残し、stepの間に通常readやpinned readを挟める。

予算はmetadataの確認件数と、bitmap上の候補pageの判定数で管理する。bitmapの1,024 bitを調べることは、媒体を1,024回読むことではない。cache hitにも作業件数を割り当て、I/Oがないからといって無制限にCPUを使わない。

ただし、件数の上限は経過時間の上限ではない。read一回が長引く場合もある。また、探索を分割しただけでは、commitのsyncや全経路が非同期になるわけではない。nativeサービスからschedulerへ制御を返す接続も、別に確かめる必要がある。

## キャッシュの費用を隠さない

同じmetadataを繰り返し読むなら、検証済みのimmutableな値をcacheできる。探索cacheの比較では、同じ128回の64 KiB更新を含むworkloadで、backend read要求が214,335,488 Bから962,560 Bへ減った。

代わりに512 KiBのdataと2 KiBのtagを保持する。常にこの容量が必要という結果ではなく、cacheへ入るleaf数と配置によって効果が変わる。読む量と使うRAMを同じ表で比較しよう。

map追加後のRV32構成では、store状態はcacheなし31,512 B、512 KiB cacheとtag込み557,848 Bだった。この値はcall stack、backend、OS file cacheを含まない。大きなcacheを外部PSRAMへ置けるか、内部SRAMに何が残るか、総量のpeakがどうなるかも、統合時には必要になる。

cacheは、毎回媒体を再検査する仕組みではない。保持している値の整合性を調べることと、cacheを捨てて媒体を読み直すことの意味も分けておきたい。

## PC上で、共有が壊れる条件を読む

前章の作業用コピーを使う。新しく始める場合の参照版は、付録のストアの行を使う。

```sh
.tools/zig-0.17.0/zig test src/root.zig \
  --test-filter 'promotion writes map metadata only' \
  --test-filter 'pinned mapped data' \
  --test-filter 'map search visits are budgeted'
```

[mapのテスト](git:8b1c3c24fae826699829488c0af2834700945a4d:src/storage/extent_map_test.zig)で、旧readerをpinしたまま更新し、物理ページを再利用する順序を追う。演習では、A、B、Cの三ページを二つの世代が共有する図を描き、Bを変えた直後、旧readerを解放した直後、旧disk rootを退役させた直後に、回収できる候補を区別しよう。

次に、mapの探索予算を小さくしたテストを読む。同じ結果へ到達することと、一回ごとの作業量を守ることの両方を、どのassertionが調べているだろうか。

小さい変更を速くする方式には、所在の表、共有、回収、cacheという新しい責任が生まれる。正しさを保ったまま改善できたと言うには、変更したデータだけでなく、変更しなかった世代と失敗時の結果も比較する必要がある。

伸長と一括更新の追加実験は、後続版の独立した作業用コピーで行う。

```sh
git worktree add --detach ../nihos-book-store-batch \
  6bb2467ac14e7cc90b4bc2dde3f45c72360ca420
cd ../nihos-book-store-batch
sh tools/bootstrap-zig.sh
.tools/zig-0.17.0/zig test src/root.zig \
  --test-filter 'truncate and regrow' \
  --test-filter 'sparse growth allocates' \
  --test-filter 'batch writes one shared map path'
```

切り詰め前のreaderを残し、新旧viewの末尾を比べよう。次に16件の変更が同じleafへ集まる図と、別のsubtreeへ散る図を描く。data量、map量、sync回数のうち何が変わるかを予想すると、次の{{ch:sqlite-persistence}}でDBの書込みを読むときの手掛かりになる。
