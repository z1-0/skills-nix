#!/usr/bin/env bash
set -euo pipefail

API_URL="https://skills-nix.vercel.app/api/repos.json"
BATCH=25
MAX_RETRIES=3

log() { echo "$*" >&2; }

fetch_batch() {
  local query="$1"
  local attempt=0

  while (( attempt < MAX_RETRIES )); do
    local resp
    if resp=$(gh api graphql -f query="$query" 2>&1); then
      echo "$resp"
      return 0
    fi

    attempt=$((attempt + 1))
    if (( attempt < MAX_RETRIES )); then
      log "    Retry ${attempt}/${MAX_RETRIES}..."
      sleep $((attempt * 5))
    fi
  done

  log "    Failed after ${MAX_RETRIES} retries:"
  log "    ${resp}"
  return 1
}

log "Fetching repos..."
mapfile -t repos < <(curl -sfL "$API_URL" | jq -r '.repos[]')
total=${#repos[@]}
batches=$(( (total + BATCH - 1) / BATCH ))
log "Found ${total} repos, ${batches} batches"

log "Querying GraphQL..."
for (( i=0; i<total; i+=BATCH )); do
  log "  Batch $(( i / BATCH + 1 ))/${batches}..."

  query="{"
  for (( j=i; j<i+BATCH && j<total; j++ )); do
    IFS='/' read -r owner name <<< "${repos[$j]}"
    query+="r${j}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } }"
  done
  query+="}"

  resp=$(fetch_batch "$query") || continue

  echo "$resp" | jq -r '
    .data | to_entries[] |
    select(.value.nameWithOwner != null) |
    [.key[1:], .value.nameWithOwner, .value.defaultBranchRef.target.oid] | @tsv
  ' | while IFS=$'\t' read -r idx redirect_target sha; do
    input="${repos[$idx]}"
    echo "https://github.com/${redirect_target}/archive/${sha}.tar.gz"

    if [[ "$redirect_target" != "$input" ]]; then
      echo "${input} -> ${redirect_target}" >> redirects.txt
    fi
  done >> urls.txt
done

log "Got $(wc -l < urls.txt) refs, $(wc -l < redirects.txt) redirects"

log "Fetching hashes..."
nix run github:z1-0/nix-bulkfetch-url -- --unpack --json < urls.txt > hashes.json

log "Building registry..."
jq -n \
  --slurpfile hashes hashes.json \
  --rawfile redirects redirects.txt '
  ($hashes[0] | map({
      key: (.url | split("/") | .[3:5] | join("/")),
      value: {
          rev: (.url | split("/")[-1] | split(".tar")[0]),
          hash: .hash
      }
  }) | from_entries) as $hashes |
  ([$redirects | split("\n")[] | select(length > 0) | split(" -> ") |
    { key: .[0], value: .[1] }] | from_entries) as $redirects |
  reduce ($redirects | to_entries[]) as $r ($hashes;
    . + { ($r.key): $hashes[$r.value] }
  ) | {
    updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    repos: (to_entries | map(.key = (.key | ascii_downcase)) | sort_by(.key) | from_entries)
  }
' > registry.json

log "Done: registry.json"
