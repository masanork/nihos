# Mounted card contextとVFS/RPCの結合

2026-10-28、実装`ad8bb03`。
cardのprobe/mountと直接readを分け、世代付きcontextのBackend/pathをRPC ownerが保持できるようにした。
contextはFS/diskの終了まで保持し、旧世代、二重mount、workspace/outputの重複を拒否する。
read中のdestroyはBusyとしてcontextを残し、成功時だけ全clearする。
[構造化結果](2026-10-28-fatfs-card-rpc-host.json)と[host/候補監査の生結果](evidence/2026-10-28-fatfs-card-rpc-host/)を保存した。

FAT12/16/32・MBR FAT32・exFAT各fixtureでcard contextを実VFS/RPC・実development brokerへ接続した。
sector callbackでcancel/exitを注入し、service parentの早期free/retire拒否、client pages回収、
未処理request/replyの破棄、rebind後の旧handle拒否と読取り、FS終了と全pool回復を確認した。
既存分を含め84シナリオ。別のcard契約試験は世代不一致、同じaddress再利用、busy destroyと
accessor保持、成功destroy後の全clear、mount失敗時のcontext非公開も検査する。
CはASan/UBSan、Zig VFS/RPCはReleaseSafeで実行した。全入力imageの前後hashが一致した。

RV32のC contextは26,104 B。dummy backend slot、RPC owner、queuesを合わせて44,928 Bを使用し、
既存policyの64 KiB service parentへ課金する。client frameの8 KiBは別ownerである。
opaque workspace寸法はtarget objectのsymbolと、native ELFのimmutable descriptorで確認した。
host構造体の26,112 Bをそのままtarget値として使っていない。

追加の`FATFS_SD_RPC=1`候補ではnative owner/client taskを同じcard contextへ接続した。
初回readの取消後にfileをclose/openし直し、短いfileでも次のreadがsector callbackへ入るようにする。
callbackは実SD readがDMA fenceを確認して戻った後で待機し、CPU1のkernel bootstrapがclientを停止する。
通知点は転送途中のabortではない。queued request/replyを捨て、再生成clientへrebindし、
旧token/epoch/reply/exitを拒否してfile prefixを2回読み、全資源を回収する受入経路である。
停止したclientのstack再利用前のpaintも調べ、replacementとの最大値を記録する。

候補は850,864 B。image/ELF/loader/sourceとstack frame、配置監査が通過した。
通常の組込みFatFs構成も回帰link監査を通過した。Python236件、Zig Debug/ReleaseSafeも成功（後者はcache）。
再buildではallocated sectionは一致し、`.debug_line`のみ相違したため、ELF全体のbitwise再現性は主張しない。
採取には固定bundleの元のimage/ELF bytesとhashを使う。

この記録はhost結合とnative候補監査までである。実機は別のNTP作業がserialを保持していたため、
今回のSD RPC候補はまだ書き込んでいない。前回の実exFAT直接readをこのtask経路の合格に数えない。
hostのexitは通知注入で、native kernelのtask停止を実行した証拠でもない。
callback/ROM/未提供frameが残るため総stack上限も未資格である。
native trialでは`--wait-for-card`により、候補の前照合後もROM downloadで待ち、
operatorのcard交換確認後だけ起動する。実機引継ぎと別カードの準備が次の条件となる。

この記録の保存後に行った[実exFAT上のnative VFS/RPC試験](2026-10-28-fatfs-card-rpc-physical.md)は、
同じ固定候補で1回のwarm USB resetを通過した。実機結果はその別記録に保持する。
