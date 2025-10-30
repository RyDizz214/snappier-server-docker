import os
import time
import json
import unicodedata
from pathlib import Path
S=os.environ.get('SCHEDULES','/root/SnappierServer/schedules.json')
I=int(os.environ.get('SCHEDULE_WATCH_INTERVAL','30'))

BAD_SPACES = {"\u202f", "\u00a0", "\u2007", "\u2060"}

def _sanitize_string(value: str) -> str:
    """Normalize unicode strings so parsing code downstream sees ASCII."""
    if not value:
        return value
    normalized = unicodedata.normalize("NFKC", value)
    for ch in BAD_SPACES:
        if ch in normalized:
            normalized = normalized.replace(ch, " ")
    return normalized

def _sanitize_container(obj):
    """Recursively apply unicode cleanup to dict/list contents."""
    changed = False
    if isinstance(obj, dict):
        for key, val in list(obj.items()):
            if isinstance(val, str):
                cleaned = _sanitize_string(val)
                if cleaned != val:
                    obj[key] = cleaned
                    changed = True
            elif isinstance(val, (dict, list)):
                if _sanitize_container(val):
                    changed = True
    elif isinstance(obj, list):
        for idx, val in enumerate(list(obj)):
            if isinstance(val, str):
                cleaned = _sanitize_string(val)
                if cleaned != val:
                    obj[idx] = cleaned
                    changed = True
            elif isinstance(val, (dict, list)):
                if _sanitize_container(val):
                    changed = True
    return changed

def normalize():
    p=Path(S)
    if not p.exists(): return
    try:
        raw=p.read_text(encoding='utf-8')
        d=json.loads(raw)
    except: return
    changed=_sanitize_container(d)
    formatted=json.dumps(d,ensure_ascii=False,indent=2)
    if changed or formatted!=raw:
        p.write_text(formatted,encoding='utf-8')
def main():
    while True:
        normalize(); time.sleep(I)
if __name__=='__main__':
    main()
