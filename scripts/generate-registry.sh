#!/usr/bin/env bash
set -euo pipefail

API_URL="https://skills-nix.vercel.app/api/repos.json"
WORKERS=16

log() { echo "$*" >&2; }

resolve_ref() {
  local repo="$1" failed_file="$2"
  local owner="${repo%%/*}" name="${repo##*/}"
  owner="${owner,,}" name="${name,,}"
  local base="https://github.com/${owner}/${name}.git"

  for ref in HEAD refs/heads/main refs/heads/master; do
    local sha
    sha=$(git ls-remote "$base" "$ref" 2>/dev/null | head -1 | cut -f1)
    if [[ -n "$sha" ]]; then
      echo "https://github.com/${owner}/${name}/archive/${sha}.tar.gz"
      return 0
    fi
  done

  local sha
  sha=$(git ls-remote --tags "$base" 2>/dev/null | tail -1 | cut -f1)
  if [[ -n "$sha" ]]; then
    echo "https://github.com/${owner}/${name}/archive/${sha}.tar.gz"
    return 0
  fi
  echo "$repo" >>"$failed_file"
  return 1
}

log "Finding repos..."
repos=$(curl -sfL "$API_URL" | jq -r '.repos[]')
count=$(echo "$repos" | wc -l)
log "Found ${count} repos"

log "Finding refs..."
touch failed.txt
echo "$repos" | xargs -P "$WORKERS" -I {} bash -c "resolve_ref '{}' failed.txt >> urls.txt" 2>/dev/null || true
refs=$(wc -l <urls.txt)
failed=$(wc -l <failed.txt)
log "Found ${refs}/${count} refs, ${failed} failed"

log "Fetching hashes..."
nix run github:z1-0/nix-bulkfetch-url -- --unpack --json <urls.txt >hashes.json

log "Building registry..."
jq -n --slurpfile hashes hashes.json '
    ($hashes[0] | map({
        repo: (.url | split("/") | .[3:5] | join("/")),
        rev: (.url | split("/")[-1] | split(".tar")[0]),
        hash: .hash
    })) | reduce .[] as $e ({}; . + {
        ($e.repo): { rev: $e.rev, hash: $e.hash }
    }) | {
        updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        repos: (to_entries | sort_by(.key) | from_entries)
    }
' >registry.json

if [[ -s failed.txt ]]; then
  log "Failed repos:"
  cat failed.txt >&2
fi

log "Done: registry.json"
