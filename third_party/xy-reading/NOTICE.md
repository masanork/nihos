# xyの読書用原典

`kusamakura.html` は夏目漱石『草枕』の青空文庫版。本文は日本で著作権保護期間満了。
底本：「夏目漱石全集3」ちくま文庫、筑摩書房、1987年。
入力：柴田卓治、校正：伊藤時也。1999年2月17日公開、2011年5月21日修正。
原典の入力・校正・底本・制作情報もHTML末尾に保持する。
https://www.aozora.gr.jp/cards/000148/files/776_14941.html

`sicp-*.xml` は Harold Abelson / Gerald Jay Sussman with Julie Sussman,
Structure and Interpretation of Computer Programs, Second Edition (1996) の抜粋。
Source Academyの比較版ソースから、Scheme版の節1.1、1.1.1、1.2.1を保存した。
原典のライセンスは CC BY-SA 4.0。全文は CC-BY-SA-4.0.txt。
https://sicp.sourceacademy.org/
https://github.com/source-academy/sicp

変換後のSICP本文も CC BY-SA 4.0 で提供する。XMLの構造・索引・JavaScript側の
分岐を除き、Schemeコードを保持し、数式をテキストへ変換した。図版はキャプションで
表示する。これは日本語訳や全巻ではない。取得元のコミットとSHA-256は sources.json。

これらの本文のライセンスを、nihosのコードのMITライセンスへ置き換えない。
生成物は assets/xy/library.json。変換スクリプトは tools/xy-library.py。
同梱Bunsenフォントは別のCC0資産（assets/xy/fonts/CC0.txt）。
