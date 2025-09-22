#!/usr/bin/env python3
import argparse, json, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

API_URL = "https://skills-nix.vercel.app/api/repos.json"
MAX_WORKERS = 8
MAX_RETRIES = 3
BACKOFF_BASE = 2
TIMEOUTS = {"git": 15, "curl": 60, "nix": 120}


def run(cmd, t="git"):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUTS[t])


def fetch_repos():
    r = run(["curl", "-sfL", API_URL], "curl")
    return json.loads(r.stdout).get("repos", []) if r.returncode == 0 else sys.exit(1)


def resolve_ref(repo):
    base = f"https://github.com/{repo.lower()}.git"
    for ref in ["HEAD", "refs/heads/main", "refs/heads/master"]:
        try:
            r = run(["git", "ls-remote", base, ref])
            if r.returncode == 0 and r.stdout.strip():
                sha = r.stdout.strip().split()[0]
                if sha != "0" * 40:
                    return sha
        except Exception:
            continue
    try:
        r = run(["git", "ls-remote", "--tags", base])
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip().split("\n")[-1].split()[0]
    except Exception:
        pass
    return None


def compute_hash(repo, rev):
    try:
        r = run(["nix", "store", "prefetch-file", "--json", "--unpack",
                  f"https://github.com/{repo}/archive/{rev}.tar.gz"], "nix")
        return json.loads(r.stdout).get("hash") if r.returncode == 0 else None
    except Exception:
        return None


def process(repo):
    repo = repo.lower().strip()
    if "/" not in repo:
        return repo, None, None, "invalid"
    for i in range(MAX_RETRIES):
        rev = resolve_ref(repo)
        if rev:
            h = compute_hash(repo, rev)
            if h:
                return repo, rev, h, None
        time.sleep(BACKOFF_BASE ** (i + 1))
    return repo, None, None, "failed"


def main():
    args = argparse.ArgumentParser().parse_args()
    repos = fetch_repos()
    if not repos:
        sys.exit(1)
    log = lambda m: print(m, file=sys.stderr)
    log(f"Processing {len(repos)}...")
    res, fail = {}, []
    s = time.time()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        fs = {ex.submit(process, r): r for r in repos}
        for i, f in enumerate(as_completed(fs), 1):
            repo, rev, h, err = f.result()
            if err:
                fail.append(repo)
                log(f"  [{i}/{len(repos)}] FAIL {repo}")
            else:
                res[repo] = {"rev": rev, "hash": h}
            if i % 100 == 0 or i == len(repos):
                log(f"  [{i}/{len(repos)}] {time.time()-s:.0f}s")
    log(f"\nDone {time.time()-s:.0f}s, {len(res)} ok, {len(fail)} fail")
    reg = {"updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "repos": dict(sorted(res.items()))}
    print(json.dumps(reg, indent=2) + "\n", end="")


if __name__ == "__main__":
    main()
