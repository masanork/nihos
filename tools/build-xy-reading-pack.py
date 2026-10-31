#!/usr/bin/env python3
"""Compile the attributed xy JSON library and its fonts into a bounded ROM pack."""
import argparse, hashlib, json, struct
from pathlib import Path
from xy_learning_pack import build as build_learning_pack
ROOT=Path(__file__).resolve().parents[1]

def build(destination):
    source=ROOT/'assets/xy/library.json'
    library=json.loads(source.read_text())
    tutorials = [
        "Tab5のxyへようこそ\n\nホームの本棚から、本や使い方を選べます。タッチで開くほか、矢印とEnterでも選べます。数字の1〜4は本棚の近道です。\n\n読書中は矢印かSpaceで次のページへ進みます。画面下のボタンで前後のページ、目次、設定へ移れます。ホームへ戻っても読書中の位置は残ります。rで続きを読めます。\n",
        "自分に合った読み心地に\n\n設定では上下で文字サイズ、左右で縦書き・横書きを選べます。vで縦横、fで明朝・ゴシック、tで明暗を切り替えます。タッチでも各項目を選べます。Enterで反映して戻ります。\n\n読書中に設定を変えても、いまのページ先頭を起点に組み直します。この端末の設定は再起動すると初期値に戻ります。\n",
        "書く・試す・しくみを読む\n\nホームのnで文書を書けます。Ctrl-Cでホームへ戻っても文書は残ります。文書はRAM上にあり、この版ではファイル保存へ接続していません。\n\n文書画面でEscを押すとミニバッファへ進めます。(+ 1 2)を入力してEnterを押すと結果を表示します。helpでキーの使い方、homeでホームを開けます。\n\n端末のしくみは「小さなOSを育てる」から章を選んで読めます。\n"
    ]
    for section,text in zip(library['items'][0]['sections'],tutorials):section['text']=text
    records=[(book,i,s) for book,item in enumerate(library['items']) for i,s in enumerate(item['sections'])]
    payload=bytearray(64+36*len(records))
    def put(data):
        offset=len(payload); payload.extend(data); return offset,len(data)
    fonts=[put((ROOT/'assets/xy/fonts'/name).read_bytes()) for name in ('BunsenMincho-Regular.ttf','BunsenGothic-Regular.ttf')]
    credits=[]
    for item in library['items']:
        credits.append(put(('\n'.join((item['author'],item['license'],item['source']))+'\n').encode()))
    for number,(book,index,section) in enumerate(records):
        title=put(section['title'].encode()); text=put(section['text'].encode())
        ruby=[]
        for r in section['ruby']:
            reading=put(r['text'].encode());ruby.append((r['start'],r['end'],*reading))
        rubies=put(b''.join(struct.pack('<4I',*r) for r in ruby))
        struct.pack_into('<9I',payload,64+number*36,book,*title,*text,rubies[0],len(ruby),*credits[book])
    learning = put(build_learning_pack(ROOT))
    struct.pack_into('<8s14I',payload,0,b'XYREAD01',1,len(payload),len(records),64,*fonts[0],*fonts[1],*learning,0,0,0,0)
    destination.parent.mkdir(parents=True,exist_ok=True);destination.write_bytes(payload)
    result={'version':1,'bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest(),'library_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'sections':[len(b['sections']) for b in library['items']],'fonts':[{'offset':p,'bytes':n} for p,n in fonts],'learning':{'offset':learning[0],'bytes':learning[1],'sha256':hashlib.sha256(payload[learning[0]:learning[0]+learning[1]]).hexdigest()}}
    destination.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path)
    print(json.dumps(build(parser.parse_args().output)))
