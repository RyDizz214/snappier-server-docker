import os, time, json, urllib.parse, requests
from pathlib import Path
TARGETS=[os.environ.get('SCHEDULES','/root/SnappierServer/schedules.json'),
         os.environ.get('EPG_CACHE','/root/SnappierServer/epg/epg_cache.json')]
SAFE=set(os.environ.get('ALLOW_HTTP_HOSTS','localhost,127.0.0.1,snappier-server').split(','))
INTERVAL=int(os.environ.get('HTTPS_WATCH_INTERVAL','20'))
PROBE_TIMEOUT=int(os.environ.get('HTTPS_PROBE_TIMEOUT','3'))
PROBE_METHOD=os.environ.get('HTTPS_PROBE_METHOD','HEAD').upper()
cap={}
def host(url):
    try: return urllib.parse.urlparse(url).hostname
    except: return None
def https_ok(u):
    try:
        if not u.startswith('http://'): return False
        https='https://'+u[len('http://'):]
        h=host(https)
        if not h or h in SAFE: return False
        if h in cap: return cap[h]
        try:
            r=requests.get(https,timeout=PROBE_TIMEOUT,stream=True) if PROBE_METHOD=='GET' else requests.head(https,timeout=PROBE_TIMEOUT,allow_redirects=True)
            ok=200<=r.status_code<400
        except: ok=False
        cap[h]=ok; return ok
    except: return False
def fix(v):
    return ('https://'+v[len('http://'):]) if (isinstance(v,str) and v.startswith('http://') and https_ok(v)) else v
def walk(o):
    ch=False
    if isinstance(o,dict):
        for k,v in list(o.items()):
            if isinstance(v,str):
                nv=fix(v)
                if nv!=v: o[k]=nv; ch=True
            else:
                if walk(v): ch=True
    elif isinstance(o,list):
        for i,v in enumerate(o):
            if isinstance(v,str):
                nv=fix(v)
                if nv!=v: o[i]=nv; ch=True
            else:
                if walk(v): ch=True
    return ch
def proc(p):
    try:
        with open(p,'r',encoding='utf-8') as f: d=json.load(f)
    except: return
    if walk(d):
        tmp=str(p)+'.tmp'
        with open(tmp,'w',encoding='utf-8') as f: json.dump(d,f,ensure_ascii=False,indent=2)
        os.replace(tmp,p)
def main():
    while True:
        for t in TARGETS:
            pp=Path(t)
            if pp.exists(): proc(pp)
        time.sleep(INTERVAL)
if __name__=='__main__':
    main()
