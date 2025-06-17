#!/usr/bin/env python3
import os, sys, time, json, argparse, requests

def jprint(**kw): print(json.dumps(kw, ensure_ascii=False))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=int(os.environ.get("HEALTH_INTERVAL_SEC","30")))
    ap.add_argument("--endpoint", default=os.environ.get("HEALTH_ENDPOINT","/serverStats"))
    ap.add_argument("--base", default=os.environ.get("SNAPPY_API_BASE","http://127.0.0.1:8000"))
    ap.add_argument("--timeout", type=int, default=int(os.environ.get("HEALTH_HTTP_TIMEOUT","5")))
    ap.add_argument("--expect-min", type=int, default=int(os.environ.get("HEALTH_EXPECT_MIN","200")))
    ap.add_argument("--expect-max", type=int, default=int(os.environ.get("HEALTH_EXPECT_MAX","399")))
    ap.add_argument("--notify-url", default=os.environ.get("HEALTH_NOTIFY_URL","http://127.0.0.1:9080/notify"))
    ap.add_argument("--warn-cooldown", type=int, default=int(os.environ.get("HEALTH_WARN_COOLDOWN_SEC","300")))
    ap.add_argument("--fail-threshold", type=int, default=int(os.environ.get("HEALTH_FAIL_THRESHOLD","3")))
    args = ap.parse_args()

    url = args.base.rstrip("/") + args.endpoint
    bad_count = 0
    last_warn_ts = 0

    while True:
        t0 = time.time()
        try:
            r = requests.get(url, timeout=args.timeout)
            ok = args.expect_min <= r.status_code <= args.expect_max
            if ok:
                bad_count = 0  # reset on success; DO NOT notify 200s
            else:
                bad_count += 1
        except Exception as e:
            ok = False
            bad_count += 1
            r = None

        if not ok:
            if bad_count >= args.fail_threshold and (t0 - last_warn_ts) >= args.warn_cooldown:
                payload = {
                    "action": "health_warn",
                    "channel": "system",
                    "title": "Health Warning ⚠️",
                    "desc": f"Health check failed: status={getattr(r,'status_code',None)}",
                    "error": getattr(r,'reason', 'timeout/connection'),
                    "exit_code": None,
                    "exit_reason": "health_probe",
                }
                try:
                    requests.post(args.notify_url, json=payload, timeout=5)
                except Exception:
                    pass
                last_warn_ts = t0
        time.sleep(max(1, args.interval))

if __name__ == "__main__":
    main()
