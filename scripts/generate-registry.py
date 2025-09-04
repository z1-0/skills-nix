#!/usr/bin/env python3
"""
Generate registry.json for skills-nix.

Fetches a list of GitHub repositories, resolves their latest commit SHA
and tarball hash, and outputs a sorted registry.json file.

Usage:
    python scripts/generate-registry.py

No external dependencies required (Python stdlib only).
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone


API_URL = "https://skills-nix.vercel.app/api/repos.json"
REGISTRY_FILE = "registry.json"
MAX_WORKERS = 32
MAX_RETRIES = 3
BACKOFF_BASE = 2  # seconds
LS_REMOTE_TIMEOUT = 30  # seconds
PREFETCH_TIMEOUT = 120  # seconds


def fetch_repo_list():
    """Fetch the list of repositories from the API."""
    print(f"Fetching repo list from {API_URL}...")
    try:
        req = urllib.request.Request(API_URL, headers={"User-Agent": "skills-nix-generator"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
            repos = data.get("repos", [])
            if not repos:
                print("Warning: No repos returned from API", file=sys.stderr)
                return []
            print(f"Found {len(repos)} repositories")
            return repos
    except Exception as e:
        print(f"Error fetching repo list: {e}", file=sys.stderr)
        sys.exit(1)


def resolve_ref(repo):
    """Resolve the latest commit SHA for a repository.

    Tries HEAD, main, master, and latest tag in order.
    Returns (rev, None) on success or (None, error_msg) on failure.
    """
    owner, name = repo.lower().split("/", 1)

    # Try HEAD first
    for ref in ["HEAD", "refs/heads/main", "refs/heads/master"]:
        try:
            result = subprocess.run(
                ["git", "ls-remote", f"https://github.com/{owner}/{name}.git", ref],
                capture_output=True,
                text=True,
                timeout=LS_REMOTE_TIMEOUT,
            )
            if result.returncode == 0 and result.stdout.strip():
                sha = result.stdout.strip().split()[0]
                if sha != "0000000000000000000000000000000000000000":
                    return sha, None
        except (subprocess.TimeoutExpired, Exception):
            continue

    # Try latest tag
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--tags", f"https://github.com/{owner}/{name}.git"],
            capture_output=True,
            text=True,
            timeout=LS_REMOTE_TIMEOUT,
        )
        if result.returncode == 0 and result.stdout.strip():
            lines = result.stdout.strip().split("\n")
            # Get the last tag (roughly latest)
            last_line = lines[-1]
            sha = last_line.strip().split()[0]
            return sha, None
    except (subprocess.TimeoutExpired, Exception):
        pass

    return None, "Could not resolve any ref"


def compute_hash(repo, rev):
    """Compute the Nix-compatible tarball hash for a repository at a given revision.

    Returns (hash, None) on success or (None, error_msg) on failure.
    """
    owner, name = repo.lower().split("/", 1)
    url = f"https://github.com/{owner}/{name}/archive/{rev}.tar.gz"

    try:
        result = subprocess.run(
            ["nix-prefetch-url", "--unpack", "--name", "source", url],
            capture_output=True,
            text=True,
            timeout=PREFETCH_TIMEOUT,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip(), None
        return None, result.stderr.strip() or "nix-prefetch-url failed"
    except subprocess.TimeoutExpired:
        return None, "nix-prefetch-url timed out"
    except Exception as e:
        return None, str(e)


def process_repo(repo):
    """Process a single repository: resolve ref and compute hash.

    Returns (repo, rev, hash, error) tuple.
    """
    repo = repo.lower().strip()
    if "/" not in repo:
        return repo, None, None, f"Invalid repo format: {repo}"

    # Retry with exponential backoff
    last_error = None
    for attempt in range(MAX_RETRIES):
        rev, err = resolve_ref(repo)
        if rev is None:
            last_error = f"ref resolution: {err}"
            if attempt < MAX_RETRIES - 1:
                time.sleep(BACKOFF_BASE ** (attempt + 1))
            continue

        hash_val, err = compute_hash(repo, rev)
        if hash_val is None:
            last_error = f"hash computation: {err}"
            if attempt < MAX_RETRIES - 1:
                time.sleep(BACKOFF_BASE ** (attempt + 1))
            continue

        return repo, rev, hash_val, None

    return repo, None, None, last_error


def main():
    """Main entry point."""
    repos = fetch_repo_list()
    if not repos:
        print("No repos to process", file=sys.stderr)
        sys.exit(1)

    print(f"Processing {len(repos)} repositories with {MAX_WORKERS} workers...")

    results = {}
    failed = []
    start_time = time.time()

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_repo = {executor.submit(process_repo, repo): repo for repo in repos}

        for i, future in enumerate(as_completed(future_to_repo), 1):
            repo, rev, hash_val, error = future.result()
            if error:
                failed.append((repo, error))
                print(f"  [{i}/{len(repos)}] FAIL {repo}: {error}", file=sys.stderr)
            else:
                results[repo] = {"rev": rev, "hash": hash_val}
                if i % 100 == 0 or i == len(repos):
                    elapsed = time.time() - start_time
                    print(f"  [{i}/{len(repos)}] {elapsed:.1f}s elapsed")

    elapsed = time.time() - start_time
    print(f"\nCompleted in {elapsed:.1f}s")
    print(f"Success: {len(results)}")
    print(f"Failed: {len(failed)}")

    if failed:
        print("\n=== Failed Repos ===")
        for repo, error in sorted(failed):
            print(f"  {repo} ({error})")

    # Build registry
    registry = {
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repos": dict(sorted(results.items())),
    }

    # Atomic write
    registry_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), REGISTRY_FILE)
    tmp_path = registry_path + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            json.dump(registry, f, indent=2, sort_keys=False)
            f.write("\n")
        os.replace(tmp_path, registry_path)
        print(f"\nRegistry written to {registry_path}")
    except Exception as e:
        print(f"Error writing registry: {e}", file=sys.stderr)
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        sys.exit(1)


if __name__ == "__main__":
    main()
