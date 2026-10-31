# Tab5: 起動スプラッシュとmainのxy入力経路

実行コードは `e0bd527`、ベースはmain `dec310d`。PR #87、#89、#90の統合後のコードで確認した。後続の証跡追加は実行コードを変更しない。

## ちらつきの原因と修正

起動時のスプラッシュと実行時のxyは同じ走査用framebufferを使う。xyには完成フレームからの差分転送が入っているが、スプラッシュでは起動段階や入力状態の更新が全画面再描画を要求し、背景消去から文字の再描画までの途中状態をDMAが読めた。起動時にタイトルや碑文が一瞬消える経路が残っていた。

`diagnostic_ui.service`の起動段階更新を`updateSplash`へ変更した。表示開始前に用意した最初の画像を使い続け、状態欄の旧文字領域だけを消去し、状態表示・染色部分・マーカーを更新する。ログ画面から戻るときは全画面再描画を維持する。追加framebufferや割込み中の描画は導入しない。追加処理は既存のforeground用Flash領域へ置き、イメージ監査の関数許可リストも限定して更新した。

全7状態への遷移について、従来の全画面描画との完成画素一致をhostで検証した。静的タイトル内のsentinelが更新を通じて保持されることも確認し、完成画像だけでは検出できない消去・再描画の回帰を防ぐ。stride padding保持と不正geometryの無書込み拒否も確認した。

## mainの入力接続と実機確認

通常のdeviceビルドは`keyboard_i2c=true`、`xy_workspace=true`。I2C `0x6d`のTab5 Keyboard → bounded HID FIFO → `session_input.Hid` → `sessionKey` → 共通`xy.scratch.Model.handle`と接続されている。serial UTF-8は`feedSerial`から同じ文書へ入る。キー一覧と未接続機能は[通常xyの入力接続](../native-session.md#normal-xy-input-connections)を参照。

対象はESP32-P4 revision v1.3、MAC `e8:f6:0a:e2:e8:9c`、16MiB Flash。書込みlockと両serial名のkernel exclusionを取得し、候補を凍結して識別後に書込み、Flash bytesを照合した。ユーザー指示どおりバックアップは省略し、SDへの書込み・フォーマットは行っていない。

- 実機のkeyboard初期化はstatus=1、firmware=1、mode=1、error_code=0、sources=3（serial + Tab5 keyboard）。
- trace候補で56状態観測が一致した。起動、serial編集、undo、help/system views、Scheme、warm reset、日本語、字体/サイズ/色/縦横設定を含む。
- 無操作10秒の観測で再描画は停止し、走査は継続、DMAエラーは0だった。
- 続いて実キーボードを観測した。初期状態を得るCtrl-Lを1 byteだけ送信し、その後の文字はserialから送信していない。serial入力数376のまま、本文長170→171→172→171→170とhashが変化した。I2Cキーボードからxy本文への接続を実機で確認した。
- 「abc、左矢印、Backspace、Ctrl-Z」の操作と、修正後のスプラッシュの見え方の確認を依頼し、ユーザーから「全く問題ないようにみえる」と報告を受けた。個々の矢印/Undoをserialの全状態で照合できたという主張ではなく、本文変化の観測とユーザーの目視報告を分けて記録する。

## 検証と残る範囲

ReleaseSafeは69/69 build steps成功、未cache部分764/764 tests成功。Python discoveryはMac build後に522件成功。static analysis（fmt・zlint・shellcheck・codegen・6 native ELF監査）、通常版/trace版deviceイメージ監査、RV32 xy fixture 39観測が成功した。通常版・trace版ともprimary SRAM heapは49,216 bytesで、48KiB基準49,152 bytesを維持した。実機で実行したのはtrace版である。

ユーザーが今回確認した範囲では問題は見えなかった。測光・高速撮影によるちらつきの定量測定、VSYNC同期のbuffer swapや操作中のtearing消失の証明は含まない。nativeのSD保存、IME、再起動後の本文/設定復元、USB/Bluetoothキーボードは今回の接続確認に含めない。

[候補識別子と証跡index](evidence/2026-10-31-xy-boot-input/index.json)、[自動実機結果](evidence/2026-10-31-xy-boot-input/physical-result.json)、[専用キーボードの状態記録](evidence/2026-10-31-xy-boot-input/keyboard-result.json)、[公開用serial抜粋](evidence/2026-10-31-xy-boot-input/physical-xy.log)を保存した。ネットワークを含む生logと候補binaryは私有build領域に保持する。
