import os, time, json
from pathlib import Path
S=os.environ.get('SCHEDULES','/root/SnappierServer/schedules.json')
I=int(os.environ.get('SCHEDULE_WATCH_INTERVAL','30'))
def normalize():
    p=Path(S)
    if not p.exists(): return
    try: d=json.loads(p.read_text(encoding='utf-8'))
    except: return
    p.write_text(json.dumps(d,ensure_ascii=False,indent=2),encoding='utf-8')
def main():
    while True:
        normalize(); time.sleep(I)
if __name__=='__main__':
    main()
