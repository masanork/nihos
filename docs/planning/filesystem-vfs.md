# 複数ファイルシステムのVFSと保存契約

2026年10月27日。実装前の設計基準。[architecture](../architecture.md)のstorage方向を具体化する。
本書の契約を実装の基準とし、API名・構造体layout・仮予算はhost PoCで確定する。
対応済み機能や電断耐性の報告ではない。SQLite固有の契約は[SQLite integration](sqlite-integration.md)に置く。

## 他の作業系統との整合

2026年10月27日の開発profile（別worktreeの`codex/storage-plan-tab5-budget`、`67c991b`にある
`docs/planning/tab5-development-profile.json`）を標準予算の一次情報とする。
本checkoutへそのbranchが統合済みという意味ではない。以下の値は同revisionへ照合したものとする。
mount 8個、global open object 32個、data-file handle 16個、storage client 8個、
appごとのlogical FD 8個、公開I/O quantum 4 KiB、path buffer 512 bytesを区別する。
FD alias、directory cursor、file objectは同じ数え方にまとめず、それぞれの枠を計上する。

共通ログ方式は別backendの研究方向であり、このVFSや最初の学習・制作環境の前提にしない。
VFS host coreは名前・権限・寿命・部分I/Oの契約を、store crash modelは媒体上のcommit・回復・GCを検証する。
共通ログへ接続する場合も同じVFS契約とSQLiteのrollback-journal契約を満たす。
標準の永続SQLite保存先はmicroSDを想定し、内蔵NORは小さな設定と最小自立構成に使う。
boot/recoveryをSD、SQLite、新しいstoreの健全性へ依存させない。

## 設計上固定すること

- OS VFSとSQLite VFS adapterを分ける。FSとデバイスの所有者はstorage serviceにする。
- 共通APIに加え、backendの能力、mountの利用方針、検証済みの保証範囲を別々に持つ。
- open、write、sync、renameという関数名だけから、永続化や電断耐性を推定しない。
- mount世代とhandle世代で抜去・再挿入・slot再利用を区別する。
- 未対応操作や未検証の保証要求は失敗させる。強い保証を弱い手順で黙って代用しない。
- 生のDBファイルとその補助ファイルはsqldの専有対象とし、一般ファイルAPIからの更新を防ぐ。

## 責務と所有者

```text
アプリのfile API ─────────────┐
sqld → SQLite VFS adapter ────┤
                            v
              storage service / OS VFS
        名前解決・mount・権限・handle・I/O順序
                            |
           littlefs / FAT・exFAT / read-only pack
                            |
           NOR read/program/erase / SD block I/O
```

最初は一つのstorage owner taskがFS instanceとdevice状態を直列に扱う。
mountごとのworkerへ分ける場合は、controller共有、ロック順序、mount管理の排他を再検証する。
アプリやsqldがFatFs/littlefs instanceやSD controllerを直接呼ぶ経路は設けない。
VFSの権限・資源tableはkernel側、backend実行とdevice所有はservice側に置く。

NORはerase前提のprogram geometryとbad blockの扱いを持ち、SDはsectorとflushの契約を持つ。
両者を「任意位置に上書きできるdisk」に平坦化しない。littlefsには直接NOR adapterを用意する。
ESP-IDFは比較用backendであり、IDF VFSの意味論やFreeRTOSの型を共通ABIへ持ち込まない。

## 対象形式と利用範囲

| 形式 | 初期用途 | 書込みを許可する条件 |
| --- | --- | --- |
| read-only packed FS | boot assets、固定教材 | 常に書込み不可。pack生成・境界検証を別途行う |
| littlefs on internal NOR | 設定、小さな原稿・個人データ | NOR adapter、cross-core Flash guard、保存・回復試験の合格後 |
| FAT12/16/32＋VFAT LFN | PCと交換するSD上の素材・教材 | 最初はread-only。一般ファイル保存とDB更新を別々に資格化する |
| exFAT | 大きなSD・4 GiBを超える配布ファイル | 最初はread-only。64-bit経路とmetadata回復を含む独立の資格化後 |

VFATはここではFATの長いファイル名拡張を指す。FAT32とexFATは同一形式ではない。
FAT32の単一ファイル上限は4 GiB−1 byte。VFSが64-bitでもbackendの上限は残る。
exFATの大きなファイル対応はtransaction-safeの意味ではない。TexFATは初期対象外とする。
根拠は[FatFs application note](https://elm-chan.org/fsw/ff/doc/appnote.html)と
[Microsoft exFAT仕様](https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification)。

SDはpartitionなしのvolumeとMBRの基本partitionから始める。GPT・複数volumeの同時mountは次段階とし、
未対応のpartition方式を見つけた場合は明示的に拒否する。初期からLBAと容量計算は64-bitにし、
partition開始位置＋長さ、sector数×sector sizeのoverflowとdevice境界を検査する。
認識失敗やdirty volumeを理由に自動formatしない。format/repairは通常mountから分離する。

## 能力、policy、検証記録

以下はABI名の案である。backend能力だけでアプリへ権限を与えず、mount policyと検証記録でさらに絞る。

| 情報 | 内容 |
| --- | --- |
| `limits` | 最大file size、component/path長、open数、転送長、directory深さ |
| `name_rules` | UTF-8との変換、大文字小文字の比較、別名、禁止文字 |
| `file_ops` | seek、truncate、create-exclusive、rename、開いたfileのrename/unlink |
| `durability` | file data/metadata sync、namespace更新の永続化、device flush |
| `replace` | 実行時の不可分な置換、電断後の旧版/新版回復をそれぞれ報告 |
| `media` | read-only、removable、sector/program/erase geometry、DMA制約 |
| `metadata` | timestampの種類・精度・timezone・時計の有効性。未対応値のvalid bit |
| `policy` | 読書き、管理専用領域、path root、quota、USB export排他 |
| `qualification` | backend/config/driver/媒体・fault model・証拠を指定した保存/DB利用profile |

情報不足は「不明」とする。`atomic_replace`や`sqlite_writable`をFS名から固定で立てない。
別mount間のrenameは`CrossDevice`で失敗する。copy＋検証＋削除は別操作にし、不可分性を約束しない。
空き容量は推定値になり得る。空き容量確認後でもwrite/syncは失敗し得るため、予約成功とは扱わない。

## 最小APIと部分I/O

共通操作の候補は`open_at`、`close`、`read_at`、`write_at`、`truncate`、`stat`、
上限つき`read_dir`、`mkdir`、`rename`、`unlink`、`sync_file`、`sync_namespace`、
`query_mount`、`unmount`とする。inode tree、POSIX互換、symlink、hardlinkは初期の前提にしない。
directory走査cursorも世代つき資源とし、変更時の継続保証と失効をbackendごとに定義する。

- file offset/sizeとLBAは64-bit。offset＋転送長と下位型への変換を検査する。
- 転送長は有界の別fieldにする。標準profileは公開1要求4 KiB以下、data-file handle 16個、
  global open object 32個、mount 8個とする。outstanding要求16個はhost側の候補上限で、
  実機の8 clientとcompletion予約枠に対応するRPC admissionを別途検証する。
  UTF-8 pathは512-byte bufferに収め、終端NULを除き511 bytes以下にする。
  backendの制限が小さい場合は小さい方を適用し、切詰めで成功させない。
- 公開I/O 4 KiB、PSRAMでのbatch、内部SD DMA上限16 KiBは異なる単位として扱う。
- `read_at`は実読出し長とEOFを返す。`write_at`は実書込み長とerrorを返し、部分成功を保持する。
  FatFsの`FR_OK`だけで全量write成功としない。
- `read_at/write_at`は共通file cursorを持たない。backendがseek＋I/Oを使う場合は同一owner内で一体に実行する。
- `create-exclusive`は存在確認＋createの間へ別要求を割り込ませない。外部writerとの共有は許可しない。
- truncate拡張部の値はbackend能力として扱う。ゼロ埋めを要求する上位操作は明示的に実装し、
  別fileや過去の領域の内容を利用者へ漏らさない。
- read-only mountはservice入口とbackend/deviceの書込み経路で拒否する。

`sync_file`は指定fileのdataと回復に必要なmetadataを下位層まで反映する操作とする。
`sync_namespace`はcreate/rename/unlinkによる名前の変化を永続化する抽象操作であり、
POSIX directory fsyncの実装を全backendへ要求するものではない。
backendがこの保証を提供できなければ`Unsupported`を返す。
flush命令が存在することと、実機媒体が故障モデル内で保証を満たすことは分けて記録する。

## 名前解決、同一性、権限

アプリは許可されたdirectory handleと相対UTF-8 pathを使う。global cwdは持たない。
NUL・不正UTF-8を拒否し、`..`とmount境界によるroot脱出、backendのdrive prefixの注入を防ぐ。
backend固有の区切り文字も検査する。Unicode正規化や小文字化をVFS全体で勝手に適用しない。
内部で使う正規形と表示名、元の名前を区別し、作成時の衝突をbackend規則で検査する。

FATの8.3別名とLFN、大文字小文字違いが同じ対象を指す場合も、open排他・DB専有を共有する。
文字列の一致だけでfile同一性を判定しない。mount世代＋backend内の同一性をserviceで管理し、
open中のrenameを初期は禁止して対応表を安定させる。backend内部IDを再起動後の永続IDとみなさない。
安定した同一性を取得できないbackendでは、管理専用directoryのalias解決と全入口の排他を立証するまでDB更新を許可しない。

FAT/exFATにPOSIX uid/modeがなくても、nihosのcapabilityでdirectoryと操作を制限する。
disk上のread-only属性とアプリの権限は別の情報にする。管理directoryへの通常rename/unlinkも拒否する。
媒体をPCへ持ち出した際の読取りをcapabilityだけで防げるとはしない。

日本語、結合濁点、非BMP文字、case-only rename、LFNと短い別名の衝突、末尾の空白・dot、
最大長のUTF-8/UTF-16変換をfixture化する。名前長はbytesと文字単位を区別して報告する。
時計が未設定ならtimestampの無効性を示す。mtimeをfile同一性や保存完了の証拠にしない。

## mountの寿命と媒体の排他

```text
Absent → Probing → MountedRO / MountedRW → Draining → Unmounted
             └→ Unsupported / Faulted
Mounted* → Removed / Faulted
```

`Draining`では新規open/要求を拒否し、sqldの終了・rollback、受理済みI/O、sync、handle閉鎖を待つ。
syncやcloseが失敗した場合はclean unmount成功を返さず、状態とdirty理由を残す。
通常unmountがopen handleで進められなければ`Busy`を返す。管理者の強制切断はdirtyな失効として区別する。

抜去・controller reset・再mountの際はmount世代を更新する。同じslot・UUID・path・同じカードでも
古いfile/directory/DB handleは`StaleHandle`で失効し、後から来たcompletionを新世代へ適用しない。
`Removed`では新規I/Oを止め、DMA停止・割込み/worker終息を確認してからbufferとdevice資源を回収する。
再挿入はprobe・policy評価・必要な回復を経て新しいmountにする。

将来のUSB mass-storage exportでは、同じblock deviceをPCとnihosで同時にmountしない。
export前にdrain/unmountし、戻ったらcacheを捨てて再probeする。二つの独立したFS instanceからの共有も禁止する。

## 保存、置換、電断後の回復

一般writeの完了は、その要求が受理・実行されたことを示す。永続保存の完了は明示的なsync/保存操作で示す。
以下を区別する。

| 契約 | 成功時 | 中断・電断時 |
| --- | --- | --- |
| 通常write | 実書込み長が分かる | 部分更新・未永続化があり得る |
| runtime rename/replace | 他の要求から見える名前の変化を規定する | 電断後の保証は別途必要 |
| durable replace | 新しい内容と名前が永続化した後に成功する | 定めた故障モデル内で旧版か新版の完全な内容へ回復する |
| managed document save | 文書IDと版を使う保存API | backend固有の復旧手順を合格したprofileだけで提供する |

`replace_file`は同じmount内で、旧版へのlease・期待版を検証し、新版の一時fileを作成して内容をsyncし、
名前を切り替え、必要なnamespace永続化を行ってから成功する上位操作とする。
単一ownerの直列化で実行時の不可分性を作れても、電断後の不可分性まで得られるわけではない。
既存fileをunlinkしてからrenameする手順をdurable replaceとして公開しない。

FatFsの`f_rename`は既存宛先への置換を行わず、open中の対象にも制約がある。
FAT/exFATのdurable replaceは初期`Unsupported`とする。
将来、世代別file＋checksum＋復旧記録でmanaged document saveを実装する場合も、
directory/FAT/allocation metadataの破損を含む故障モデルを先に定める。
二つfileを作っただけで旧版保全を主張しない。満杯や別更新で旧版まで失う条件も検査する。
任意のPC互換pathへの置換と、nihos管理文書の版保存は別APIにする。

同時編集の上書きを防ぐため、保存要求に期待する文書版を持たせ、相違は`Conflict`で返す。
activeなSQLite DBはこの操作で置換しない。配布packは新版を別に検証し、既存leaseが閉じてから切り替える。
媒体破損時に旧版か新版を確定できなければ`RecoveryRequired`とし、勝手に古い方へ戻して保存成功にしない。
回復不能な媒体故障まで保証するものではなく、backup/exportも別機能として必要になる。

## 要求、取消、エラー

要求はclient ID、request ID、mount/handle世代、deadline、buffer leaseを持つ。
受理時にcompletion用の枠も確保し、queue満杯で完了通知を失わないようにする。
drain・取消・回復のcontrol枠と最小bufferは通常I/Oと別に予約し、資源満杯で回復まで停止させない。
待機中のsqldはschedulerでparkし、storage ownerを待ちながらspinしない。
storageはsqldへの同期callbackを行わず、callerのlockを保持したままI/Oを待つ経路を作らない。

取消はrequest IDごとの別の有界control経路で受ける。満杯の通常queueの後ろにしか取消を置けない設計にしない。
未実行なら取消可能、実行中ならbackendの安全な境界で止める。期限切れはDMA完了やbuffer解放の意味ではない。
serviceが終端completionを一度だけ返し、deviceがbufferへ触れないことを確認するまでleaseを保持する。
client終了時も同じ終息手順を使い、task heapを先に回収しない。

| エラー群 | 扱い |
| --- | --- |
| `NotFound / Exists / InvalidName / TooLarge` | 通常の名前・範囲の失敗。pathを切詰めない |
| `PermissionDenied / ReadOnly / Unsupported / CrossDevice` | 権限・policy・能力の不足を区別する |
| `Busy / QueueFull / OutOfMemory / NoSpace` | 再試行条件と部分書込み長を残す |
| `Removed / StaleHandle / IoError / Corrupt` | 対象とmountの状態を更新し、必要なら書込みを停止する |
| `Cancelled / TimedOut` | 副作用なしと確認できた場合だけ、そのように報告する |
| `OutcomeUnknown / RecoveryRequired` | write/保存が反映された可能性を残し、無条件再送を禁止する |

write/flush発行後のtimeoutを「何も書かなかった」と扱わない。driverが制御を取り戻せなければ
該当deviceを隔離し、bufferを保持したまま他serviceを動かす。再利用前には停止/resetと終息確認が必要である。
汎用file writeのrequest IDだけで再起動後の重複排除ができるとはしない。

## 性能と資源の上限

大きなasset読出しとDBの小さなランダムI/Oを同じFIFOで無制限に処理しない。
転送を有界chunkに分け、deadline/budgetで公平に選ぶ。DBのsync順序は維持しつつ、
無関係なreadと短いcontrol要求を処理できるか測る。満杯付近のcluster探索とdirectory走査も測定対象にする。
priority inheritance等の必要性は、低優先clientのI/Oが高優先clientを待たせる試験で判断する。

FS metadata cache、file buffer、block cache、SQLite page cache、DMA bounce bufferを別々に計上する。
PSRAM上の利用者bufferを無条件にDMA可能とせず、alignment・cache ownership・Flash停止中の可用性を検査する。
SDの512-byte logical sectorを、そのまま電断で巻き込まれる最大範囲とみなさない。
device flush・書込み順序・故障影響範囲が不明なら、強い耐久profileは未資格のままにする。

FatFs採用時はversion/source hash/licenseと`ffconf.h`を固定する。LFN/UTF-8 API、exFAT、
`FSIZE_t`と`LBA_t`、sector size、open上限、LFN bufferのstack/heap予算を監査する。
`FF_FS_LOCK`は不正な重複open等の抑止であり、SQLiteの段階的file lockとは別物である。
read-only buildでは同optionを0にする制約も踏まえ、service自身の専有管理を省略しない。
`FF_FS_REENTRANT`だけでmount管理やdevice排他まで安全になるとは扱わない。
詳細は[FatFs設定](https://elm-chan.org/fsw/ff/doc/config.html)、
[rename](https://elm-chan.org/fsw/ff/doc/rename.html)、
[write](https://elm-chan.org/fsw/ff/doc/write.html)、
[CTRL_SYNC](https://elm-chan.org/fsw/ff/doc/dioctl.html)を参照する。
littlefsは[upstream](https://github.com/littlefs-project/littlefs)の設定とblock adapter契約を固定して評価する。

## 実装と検証の順序

各段階の証拠をhost、target build、emulator、ESP-IDF-hosted実機、native実機で分ける。
全項目は未完了の受入条件であり、文書作成をもって合格にしない。

| 段階 | 受入条件 |
| --- | --- |
| V1: host共通VFS | fake backendで能力不足、overflow、権限、alias、handle世代、部分I/Oを検査する |
| V2: read-only形式 | pack/FAT/exFAT imageを読み、日本語名、断片化、壊れたdirectory/cluster chain、循環・範囲外参照を有界に拒否する |
| V3: littlefs保存 | program/erase/sync各境界の故障、満杯、旧版/新版の回復、他fileへの影響を検査する |
| V4: native device | NOR guard、SD geometry/DMA、抜去/reset、取消後のbuffer寿命とframe干渉を実機で確認する |
| V5: FAT/exFAT一般write | create/extend/truncate/rename/unlink、cache flush、満杯と電断後のvolume整合性を形式別に評価する |
| V6: SQLite | [SQLite integration](sqlite-integration.md)のS1〜S6をmount profileごとに通す |

読出しは2 GiB・4 GiB境界、末尾、unaligned転送を試す。下位形式の上限超過は書込み前に拒否する。
電断試験は最後のRAM状態からの続行ではなく、cacheを捨てた新規mountで検証する。
故障注入はwriteのprefixだけでなく、故障モデル内のtorn write・未sync writeの消失/並替えを含める。
再挿入した別媒体へ古い要求が届かないこと、late completion、queue満杯時の取消、client死亡、
sync失敗後の再試行、USB export排他、PC側での読出し/検査も対応段階で確認する。

検証記録にはbackend/config/driver/media ID、seed、操作列、失敗位置、再mount後のhashと回復判定を保存する。
実機ではfirmware hash、媒体型番、電源条件、電断位置、反復数、失敗例を残す。
読み取り対応、一般保存対応、SQLite書込み対応を別々に公表する。
