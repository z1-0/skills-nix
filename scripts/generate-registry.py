#!/usr/bin/env python3
"""
Generate registry.json for skills-nix.

Fetches a list of GitHub repositories, resolves their latest commit SHA
and tarball hash, and outputs a sorted registry.json file.

Designed for CI use (GitHub Actions with nix installed via cachix/install-nix-action).
"""

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone


API_URL = "https://skills-nix.vercel.app/api/repos.json"
REGISTRY_FILE = "registry.json"
MAX_WORKERS = 32
MAX_RETRIES = 3
BACKOFF_BASE = 2
LS_REMOTE_TIMEOUT = 15
PREFETCH_TIMEOUT = 60


def fetch_repo_list():
    """Fetch the list of repositories from the API."""
    print(f"Fetching repo list from {API_URL}...")
    result = subprocess.run(
        ["curl", "-sfL", API_URL],
        capture_output=True, text=True, timeout=60
    )
    if result.returncode != 0:
        print(f"Error: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    repos = json.loads(result.stdout).get("repos", [])
    print(f"Found {len(repos)} repositories")
    return repos


def resolve_ref(repo):
    """Resolve the latest commit SHA. Tries HEAD, main, master, latest tag."""
    owner, name = repo.lower().split("/", 1)

    for ref in ["HEAD", "refs/heads/main", "refs/heads/master"]:
        try:
            result = subprocess.run(
                ["git", "ls-remote", f"https://github.com/{owner}/{name}.git", ref],
                capture_output=True, text=True, timeout=LS_REMOTE_TIMEOUT,
            )
            if result.returncode == 0 and result.stdout.strip():
                sha = result.stdout.strip().split()[0]
                if sha != "0" * 40:
                    return sha, None
        except (subprocess.TimeoutExpired, Exception):
            continue

    try:
        result = subprocess.run(
            ["git", "ls-remote", "--tags", f"https://github.com/{owner}/{name}.git"],
            capture_output=True, text=True, timeout=LS_REMOTE_TIMEOUT,
        )
        if result.returncode == 0 and result.stdout.strip():
            sha = result.stdout.strip().split("\n")[-1].strip().split()[0]
            return sha, None
    except (subprocess.TimeoutExpired, Exception):
        pass

    return None, "Could not resolve any ref"


def compute_hash(repo, rev):
    """Compute the Nix-compatible tarball hash."""
    owner, name = repo.lower().split("/", 1)
    url = f"https://github.com/{owner}/{name}/archive/{rev}.tar.gz"

    try:
        result = subprocess.run(
            ["nix-prefetch-url", "--unpack", "--name", "source", url],
            capture_output=True, text=True, timeout=PREFETCH_TIMEOUT,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip(), None
        return None, result.stderr.strip() or "nix-prefetch-url failed"
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except Exception as e:
        return None, str(e)


def process_repo(repo):
    """Process a single repository with retries."""
    repo = repo.lower().strip()
    if "/" not in repo:
        return repo, None, None, f"Invalid format: {repo}"

    last_error = None
    for attempt in range(MAX_RETRIES):
        rev, err = resolve_ref(repo)
        if rev is None:
            last_error = err
            if attempt < MAX_RETRIES - 1:
                time.sleep(BACKOFF_BASE ** (attempt + 1))
            continue

        hash_val, err = compute_hash(repo, rev)
        if hash_val is None:
            last_error = err
            if attempt < MAX_RETRIES - 1:
                time.sleep(BACKOFF_BASE ** (attempt + 1))
            continue

        return repo, rev, hash_val, None

    return repo, None, None, last_error


def main():
    repos = fetch_repo_list()
    if not repos:
        sys.exit(1)

    print(f"Processing {len(repos)} repositories...")
    results = {}
    failed = []
    start = time.time()

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(process_repo, r): r for r in repos}
        for i, future in enumerate(as_completed(futures), 1):
            repo, rev, hash_val, error = future.result()
            if error:
                failed.append((repo, error))
                print(f"  [{i}/{len(repos)}] FAIL {repo}: {error}", file=sys.stderr)
            else:
                results[repo] = {"rev": rev, "hash": hash_val}
            if i % 100 == 0 or i == len(repos):
                elapsed = time.time() - start
                print(f"  [{i}/{len(repos)}] {elapsed:.0f}s")

    elapsed = time.time() - start
    print(f"\nDone in {elapsed:.0f}s, {len(results)} ok, {len(failed)} failed")

    if failed:
        print("\nFailed repos:")
        for repo, err in sorted(failed):
            print(f"  {repo} ({err})")

    registry = {
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repos": dict(sorted(results.items())),
    }

    path = os.path.join(os.path.dirname(os.path.dirname(__file__)), REGISTRY_FILE)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(registry, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print(f"Registry written to {path}")


if __name__ == "__main__":
    main()
