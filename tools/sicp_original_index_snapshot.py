#!/usr/bin/env python3
"""Fetch MIT Press original HTML and emit exercise anchors with page hashes."""
import urllib.request,re,hashlib,json,concurrent.futures
from html import unescape
base='https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/full-text/book/'
toc=urllib.request.urlopen(base+'book-Z-H-4.html',timeout=30).read()
pages=sorted(set(int(x) for x in re.findall(rb'href="book-Z-H-(\d+)\.html#%_sec_[1-5]\.',toc)))
def fetch(n):
 name=f'book-Z-H-{n}.html'; raw=urllib.request.urlopen(base+name,timeout=30).read(); text=raw.decode('latin-1'); return n,name,raw,text
rows=[]; hashes={}
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
 for _,name,raw,text in pool.map(fetch,pages):
  hashes[name]=hashlib.sha256(raw).hexdigest()
  pat=r'<a\s+name="%_thm_([1-5]\.\d+)"></a>\s*<b>Exercise\s+\1\.</b>'
  for m in re.finditer(pat,text,re.I):
   markers=list(re.finditer(r'<a\s+name="%_sec_([1-5](?:\.\d+){1,2})"',text[:m.start()],re.I))
   rows.append({'id':m.group(1),'section':markers[-1].group(1) if markers else None,'url':base+name+'#%_thm_'+m.group(1)})
rows.sort(key=lambda x:tuple(map(int,x['id'].split('.'))))
expected = {f'{c}.{i}' for c, maximum in enumerate((46,97,82,79,52), 1) for i in range(1, maximum+1)}
if len(rows) != len(expected) or {r['id'] for r in rows} != expected: raise ValueError('original exercise anchors changed or duplicated')
print(json.dumps({'toc':base+'book-Z-H-4.html','toc_sha256':hashlib.sha256(toc).hexdigest(),'page_sha256':hashes,'exercises':rows}, indent=2))
