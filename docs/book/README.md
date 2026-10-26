# nihosのOS書籍

nihosを教材に、OSの仕組みと実機での設計判断を学ぶ書籍の土台です。書名と構成は検討中です。

- [企画案と類書調査](proposal.md): 読者、差別化、目次案、演習、エコシステムへの導線。
- [試読本文](ja/preface.md): 境界、host実験、有限メモリ、native起動の四章。
- [Zigが動き始めるまで](ja/native-entry.md): スタックと初期値、最初の例外復帰、ELF配置の実験。
- [章の雛形](chapter-template.md): 新しい章を育てるときの共通項目。

## 試し組み

Node.js 22.12以降とnpmを使用します。依存のバージョンはpackage-lock.jsonで固定します。

```sh
cd docs/book
npm ci
npm run check
npm run build
npm run build:web
npm run preview
```

PDFは `output/pdf/nihos-book-sample.pdf`、Web Publicationは `output/web/` へ生成します。初回のPDFビルド時にはVivliostyleがブラウザを取得する場合があります。Webの確認は `npx --no-install vivliostyle preview -c vivliostyle.config.cjs`、または生成先をHTTPで配信して行います。HTMLの目次は `output/web/_build/ja/toc.html` にあります。

`npm run check` は原稿、章参照、リポジトリ内の参照先、コード抜粋のアンカーを検査し、`_build/` に原稿と出典情報を生成します。OSの動作は検証しません。各章の実験は別に実施します。プレビュー中に原稿やソースを変更した場合は、別のターミナルで `npm run check` を再実行してください。

間接依存の既知の脆弱性に対して `package.json` の `overrides` を指定しています。依存更新時は `npm audit` とPDF・Webの両方のビルドで互換性を確認します。

## 原稿を増やす

`book.cjs` が章順の正本です。`ja/<id>.md` を作り、同ファイルにentryを追加します。章のH1には章番号を付けず、章間参照は `{{ch:<id>}}` と書きます。目次・番号は生成物にだけ挿入します。

リポジトリ内の資料には `[説明](repo:docs/architecture.md)` の形でリンクできます。前処理が存在を確認し、ビルド時点のコミットに固定したGitHubリンクへ変換します。コードは `{{snippet:<id>}}` で取り込み、抜粋の範囲は `scripts/prepare.mjs` で指定します。ソース変更でアンカーが見つからない場合は、古いコードを黙って掲載せずビルドを停止します。

`_build/source.json` はカーネル側のコミットと未コミット変更の有無、抜粋元ファイルと抜粋コードのSHA-256を記録します。未コミットの原稿を含む試し組みであり、これ自体はリリースの証明にはなりません。公開時には原稿も含めて版を固定し、コミット、実験記録、toolchainを対応づけます。

## 参照した組版

monbanの `docs/book/ja/` にあるA5・Markdown・Vivliostyle techbook、章番号生成の運用を参考にしました。このディレクトリのCSSと前処理はnihos用に独立して記述し、monbanの本文・画像・コードはコピーしていません。monbanへのローカルパス依存はありません。

Vivliostyleの設定は[公式設定リファレンス](https://docs.vivliostyle.org/en/cli/config/)に基づきます。テーマはbare package名ではなくインストール済みのローカルパスを指定します。本文のライセンスは、別途の指定がない限りリポジトリの[LICENSE](../../LICENSE)に従います。参照先の書籍・仕様や依存パッケージにはそれぞれのライセンスが適用されます。
