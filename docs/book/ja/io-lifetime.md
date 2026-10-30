# タスクが終わっても、仕事は終わらない

ファイルを読み始めたアプリケーションを、利用者が閉じた。OSはそのメモリを次のアプリケーションへ貸した。少し後で、古い読取りの結果が同じ場所へ書かれたらどうなるだろうか。

{{ch:task-lifetime}}では、終了したタスクのスタックを、実行を離れてから回収した。{{ch:process-isolation}}では、不正アクセスをした保護タスクも止められるようになった。{{ch:machine-basics}}で見たDMAのような転送回路まで含め、ここではCPUの外まで寿命を広げる。別のCPU、サービス、DMAが仕事を持つ場合、要求元の終了だけでは、渡した領域が使われなくなったと判断できない。

## 読取りの要求は、いつ終わるか

タスクがストレージへ読取りを頼むと、要求を受けた側は、データを入れるバッファを使い始める。タスクは結果を待ち、完了したら受け取る。要求を取り消した場合も、転送装置がすでにバッファを使っているなら、取消しの通知だけで領域を再利用してはいけない。転送が停止し、装置が手を離したことを確認して初めて返せる。

{{figure:io-request-flow}}

要求したタスクが途中で終了する場合もある。そのとき「結果の送り先がもうない」と「装置がメモリを使っていない」は別の事実である。以下では、名前の有効性と実際の借り手を分けて追う。

## 名前を消すことと、手を離すこと

アプリケーションの名前やハンドルを無効にする処理は、古い要求を拒否するために必要である。ただしDMAは、タスクの世代番号を見て書込みを止めてくれない。PMPによるCPUのアクセス制限も、発行済みのDMAを止めたり、別CPUの借りたポインタを失効させたりはしない。保護タスクを終了値`-70`で止めたことから、転送先を即座に返してよいとは判断できない。今回のPMP試験は、DMA利用中のU-modeアプリの破棄を検証したものではない。

そこで、名前の有効性と、実際に領域を使う者の存在を別に管理する。[メモリのbroker](git:29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239:src/kernel/memory_broker.zig)は、所有者ごとの割当上限と、ページをまとめた領域の貸出しを管理する。その領域を別の処理へ渡す前に`pin`し、使い終わったことを確かめてから`unpin`する。

pinは「この領域をまだ再利用してはいけない」という記録である。書込みを防ぐハードウェアでも、借りたポインタを自動で追跡する機構でもない。いつpinし、何を確認して外すかは、呼出し側の契約になる。

{{figure:io-owner-lifetime}}

## 一つの所有者にも、複数の借り手がいる

{{figure:io-release}}

図ではownerの終了後もpinが残る。取消を要求しただけで回収可能へ飛ばず、転送停止や参照終了を確認してからpinを外す。他の借り手がいれば、最後の一人が手を離すまで待つ。

同じ領域を二つの仕事が使うなら、それぞれのpinが必要になる。一つの完了を受け取って、両方が終わったことにしてはいけない。

{{snippet:broker-unpin}}

完了を表す識別子、tokenは、brokerの実体、slot、ticketに結び付けられ、一度だけ消費する。二重の完了や古い完了でpinの数を減らすと、まだ使っている領域を返す原因になるからだ。

所有者の終了処理は、新しい貸出しを止める段階と、回収する段階に分かれる。`beginClose`で閉じ始め、`reclaimOne`はpinのない領域を一つずつ返す。残るpinがあれば`waiting`となる。大きな回収を割込み内で一度に行うことも避ける。

所有者が複数のタスクを含む場合は、その全体が停止したことを呼出し側で確認する。一つの兄弟タスクが終了しただけでは、所有者を閉じてよい理由にならない。

## 完了したI/Oでも、届ける相手はいないことがある

要求元が終わっても、開始済みの読取りを正常完了まで進める方式がある。ドライバを途中で止める処理を増やさず、転送先を保持したまま、完了後に結果だけ捨てる。

[実機の強制終了試験](git:29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239:docs/measurements/2026-10-27-broker-sd-lifetime.md)は、この方式を使った。CPU0が領域をpinしてSDへCMD17を発行し、CPU1の待機中clientを強制終了させる。その後にCPU0が読取りとコピーを完了し、古いclientへの応答を捨て、pinを外して回収を進めた。

この試験のDMA先は内部SRAMの512バイトのstagingであり、そこからPSRAMへコピーする。pinはコピーまでを含む処理全体を保護する。CMD17の発行後、ソフトウェア上の完了前にclientを止めたが、その瞬間にもsiliconの転送が続いていたかまでは測っていない。

三回のUSBリセット起動で、終了後のfree拒否、応答一件の破棄、回収後の全容量回復、古いidentityとleaseの拒否を確認した。終了、転送、応答、回収を一つの成功表示へまとめず、順序を観測することが大切である。

## メモリを引き継いでも、時計が止まっていた

この経路は最初から動いたわけではない。前のstorageサービスが終了時にTG1のcounterを停止していたのに、後のSDドライバは同じタイマーを保持していた。ドライバのdelayは、進まないcounterを待って止まった。

修正では、後続の処理がTG1を単独で取得し直し、設定と動作を確認してからI/Oを始め、完了後に止めて返した。領域とポインタの寿命が整っていても、周辺資源の寿命が抜けることがある。

| 渡すもの | 次の利用者が確かめること |
| --- | --- |
| メモリ | 古い利用者とpinが残っていないか |
| controller | 前の転送と割込み状態が残っていないか |
| タイマー | 設定が合い、counterが動いているか |
| 応答の宛先 | 同じslotでも、同じ世代の相手か |

資源をまとめる設計を考えるときは、バイト列だけでなく、それを使う処理の依存先も書き出してみよう。

## 取消しの通知は、転送停止の証拠ではない

正常完了を待つ方式だけでは、相手が応答しない場合に困る。取消しや抜去では、controllerの停止を確認してから領域を返す必要がある。

[SDドライバの寿命試験](git:29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239:docs/measurements/2026-10-27-native-storage-io-physical.md)では、CMD17発行後に取消しまたは抜去の通知を入れ、成功結果を公開しないことを調べた。DMA停止、descriptorの切離し、キャッシュの返却などを確認した後でleaseを回収する。取消し前のデータが、読取り成功のように利用者のbufferへ出てはいけない。

停止の確認にも失敗したなら、時間が来たという理由だけでpinを外せない。領域を隔離したままにする費用と、再起動などの回復方針を考える。取消し要求を受け付けること、デバイスが静止したこと、領域を再利用できることは、それぞれ違う段階である。

後続の[実カード抜去試験](git:29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239:docs/measurements/2026-10-27-sd-removal-physical.md)では、人がカードを抜き、次の読取りがtimeoutになった後、停止とlease返却を確認した。同じカードを戻すと新しいsessionで容量とLBA 0のCRCを照合でき、旧ticketを拒否した。これはread-onlyの試験である。書込み途中のデータの復旧は、{{ch:durable-storage}}で別に扱う。

## ファイルのハンドルも、世代をまたがせない

ファイルを読む経路には、名前を解決する仕事と、開いた対象からbyteを読む仕事がある。VFSはrootやmount、権限、handleの寿命を扱い、backendがfile identityとoffsetからデータ位置を求める。

{{figure:vfs-layers}}

実線は本章で扱うFatFs側の経路、破線は後の章の独自storeと比較する経路である。両者が一つのnative構成へ接続済みという意味ではない。FATではclusterのつながりを辿り、独自storeではobjectとpage mapを辿る。同じread APIの下にも、異なるデータ構造を置ける。

POSIXのfile descriptorと比較する場合も、名前、開いた参照、媒体上のデータを分けて見る。nihosのoffset指定の読取りでは、共有する現在位置を持つ方式とは契約が違う。以下では、開いた参照がどの媒体のどの世代に属するかへ注目する。

デバイスが再び使えることと、古いファイルハンドルが再び使えることは別である。サービスやmountのsessionを変えたら、以前のclientの要求と応答を見分けたい。

[storageサービスの再接続](git:29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239:docs/measurements/2026-10-26-tab5-storage-rebind.md)では、clientの世代と、通信の接続世代を表すepochを照合する。同じslotへ新しいclientが入っても、古いfile handleを受け付けない。後から届いた応答も、新しい要求の結果として渡さない。

このためには、VFSの名前や操作だけでなく、I/Oが終わったと判断する条件も揃える必要がある。ファイルAPIが正しく見えても、下のドライバが領域を使い続ければ、上の回収だけを正しくすることはできない。

## FatFsの作業領域は、clientと別の寿命にする

ここまでのnative実機試験は、固定したread-only経路だった。[後続のFatFs接続](git:f02a1674b87fe195c71b549f6cc325661120529d:docs/measurements/2026-10-28-fatfs-rpc-host.md)では、実FatFs、ZigのVFS、RPC、brokerをホスト上でつないだ。FAT12、FAT16、FAT32、MBR FAT32、exFATを読み、途中の取消しやclient終了を注入した。

FatFsは、mountの状態や開いたfile、検査済みのlookup結果などを保持する。これらをclientが閉じる領域へ置くと、file APIを呼んでいる最中に消える危険がある。そこで、サービス所有の64 KiB parentへ、disk、FatFs backend、VFSを含むRPC owner、queueをまとめる。dispatch中はpinを保持する。

RV32の型と整列から求めた使用末尾は38,656 Bだが、brokerのchargeは64 KiBである。client側のframeとstack、コードはこの数に含まれない。型が入ることを確かめた段階であり、最終native imageの配置や実行が通ったという結果ではない。

要求と返信はコピーし、messageにclientのポインタや自己申告のprincipalを入れない。kernel側の入口でidentityを結び付ける。clientを止めてもservice parentのfreeは`Busy`となり、client自身から返そうとしても`WrongOwner`で拒否する。

## キャッシュにあっても、古い媒体のbyteを返さない

媒体が失効しても、FatFsのfile objectには既に読んだ情報が残り得る。次のsector I/Oだけを禁止しても、cacheの値がそのまま返れば、古いsessionを使えてしまう。

[VFSへの接続試験](git:f02a1674b87fe195c71b549f6cc325661120529d:docs/measurements/2026-10-28-fatfs-vfs-host.md)では、fileを一度読んだ後に失効させ、cacheのbyteも返さず、新しいsector I/Oも出さないことを確かめた。lookupで検証したfile objectを固定slotへ保持し、open時に名前を解決し直さない。名前、検証した実体、その寿命を結び付けるためである。

途中のI/O失敗では、公開readのcountを0にし、呼出し元の出力を変えない。mountをfault状態へ進め、閉じ直す前の再試行で元気になったように扱わない。新しいsessionでは、以前のroot、file、backend epochをI/O前に拒否する。

取消しは、同期backendがfence済みで戻るのを待ち、返信のdataを消して取消し結果を返す。client終了では未実行requestと未読replyを捨て、owner側でfileを閉じる。終了の順序はRPC shutdown、非公開FSの破棄、parent全体の消去、unpin、freeとなる。

これらの69 scenarioはホストの同期sector callbackでの結果である。実taskの強制終了やDMA途中の抜去を同時に測ったわけではない。下位ドライバがfenceを成立させて戻る契約を、上位の実FatFsを使っても守れるか、という接続の検査になる。

## センサーの初期化も、長い一回の仕事にしない

入力の一例として、Tab5のBMI270を考えよう。chip IDが読める状態から、加速度と角速度の六軸を読むまでには、8,192 Bの設定のuploadと、初期化完了の確認が必要だった。

[ドライバ](git:ae248b92c0d3b675c4650340f0e184ea9744cea5:src/board/tab5/bmi270.zig)は、一回のpollでI2C転送を最大一回にし、待ち時間は次のpollまで残す。32 Bずつのuploadでも、すべて終わるまでloopを占有しない。待機の開始時刻は、pollへ入った時刻ではなく、転送が完了した時刻から計算する。転送自体が長かった場合にも、機器が要求する待ち時間を省略しないためである。

読取りでは加速度と角速度の両方のdata-readyを確認し、符号付きの値を一組として渡す。新しい値がないことを、前のsampleが新しく届いたことにしてはいけない。timeoutやI2C失敗では、以前の値を有効な最新値として残さない。

[同じ候補の三起動](git:ae248b92c0d3b675c4650340f0e184ea9744cea5:docs/measurements/2026-10-27-native-imu.md)では、毎回sensorをresetして設定を送り直し、継続するsample数と、おおむね1 gの加速度の大きさを確認した。画面、両CPUのtimer、BLE探索も進んだ。

設定は100 Hzだったが、表示やC6と共有するloopでの取得は約40回／秒だった。sensorの生成周期、OSが読めた頻度、ログの表示頻度を分ける必要がある。FIFOやIRQによる欠落のない取得、動かしたときの軸対応、角速度の校正は、この試験とは別の課題である。

## 音を送り終えるとは、どこまでか

音声では、CPUが用意したPCMをDMAがI2Sへ渡し、codecと増幅器が出力を担当する。転送先が空になったこと、最後のdescriptorへ到達したこと、DMAが止まったこと、音が聞こえたことは異なる観測である。

[有限PCMの実機試験](git:ae248b92c0d3b675c4650340f0e184ea9744cea5:docs/measurements/2026-10-28-native-audio.md)は、1 KiBの変更しないPCMを32個のdescriptorから参照する。連結の最後はnullで、8,192 frame、設定上512 msの16-bit stereoを送る。通常の連続streamingやアプリケーション向け音声APIを先に作るのではなく、開始から返却までを有限にした。

準備中はmuteし、I2SとDMAの開始に成功してから解除する。終了では最後のdescriptorとclock、FIFOの進捗を確認し、drain区間を挟んで出力を止める。muteに失敗してもDMA停止を試し、DMA停止に失敗してもcodecの停止を試す。一つのcleanupの失敗で、ほかの後始末を飛ばさない。

{{snippet:audio-cleanup}}

実機ではclock counter 262,145、FIFO sample counter 16,384、最終descriptor、DMAのparked状態を照合した。codec停止、DMA停止、所有権の返却も確認した。聞こえたという利用者の確認やアナログ信号の測定は、この記録に含まれない。

最初はcodecの予約bitを含むbyte全体の照合で止まり、別の候補はDMA blockのbase addressを取り違えて例外になった。書いてよいbitだけを照合し、失敗段階と`mtval`で不正なdata addressを切り分け、修正後の候補を確かめた。MMIOが読めること、正しい周辺回路を操作していること、最後に静止したことを段階ごとに見る。

## PC上で、二人目の借り手を残す

```sh
git worktree add --detach ../nihos-book-io \
  29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239
cd ../nihos-book-io
sh tools/bootstrap-zig.sh
.tools/zig-0.17.0/zig test src/root.zig \
  --test-filter 'separate pins' \
  --test-filter 'cancel and removal'
```

[brokerのテスト](git:29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239:src/kernel/memory_broker_test.zig)の`separate pins prevent premature reaping and consume completion tokens once`を読む。二つのpinを一つずつ外したとき、freeと回収がいつ成功するかを、実行前に表へ書こう。同じ完了tokenを二度渡したとき、どの情報で拒否するだろうか。

次に[SDのテスト](git:29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239:src/soc/esp32p4/sdmmc.zig)を読み、取消しをcommand、data、copyの各境界へ入れた場合を比べる。演習では、要求元が閉じた後にも二つの借り手が残る順序を紙に描き、応答先の失効と領域の回収を別々に置こう。

応答の早さを求めて直ちに取消し完了を返す方式と、停止まで待つ方式では、誰が残りの仕事を持つだろうか。利用者へ返す完了の意味を決めることは、実装の都合を越えたAPIの設計になる。

追加のFatFs実習は、ホストにC/C++ compiler、Python 3と、RV32のobject compileに使う固定toolchainを用意し、別の作業用コピーで実行する。詳しい環境は同じ版の[probe資料](git:f02a1674b87fe195c71b549f6cc325661120529d:probes/fatfs-disk/README.md)を使う。

```sh
git worktree add --detach ../nihos-book-fatfs \
  f02a1674b87fe195c71b549f6cc325661120529d
cd ../nihos-book-fatfs
python3 tools/check-fatfs-backend.py
```

runnerは新しい通常fileを使う。疎なexFAT imageの論理長は6 GiBで、前後のhashでは全体を読む。実カードとしてmountする操作はない。clientを止めたときのparent、file、返信の順序を、生成した`backend-results.json`から追おう。

センサーと音声の状態遷移は、同じ版に含まれるホストテストで調べる。

```sh
git worktree add --detach ../nihos-book-peripherals \
  ae248b92c0d3b675c4650340f0e184ea9744cea5
cd ../nihos-book-peripherals
sh tools/bootstrap-zig.sh
.tools/zig-0.17.0/zig test src/board/tab5/bmi270.zig
.tools/zig-0.17.0/zig test src/audio/playback_probe.zig
.tools/zig-0.17.0/zig test src/audio/tone.zig
```

演習では、音声開始前の失敗、開始後のtimeout、DMA停止の失敗を表にし、各場合に`returned`を許せるか予想する。センサーでは、転送が長引いた場合に待ち時間をどこから数えるかを追おう。どちらも機器へ書き込まず、模擬busとclockで判断を確かめる。
