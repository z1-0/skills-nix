#!/usr/bin/env bash
set -euo pipefail

API_URL="https://skills-nix.vercel.app/api/repos.json"
BATCH=25
MAX_RETRIES=3

URLS="urls.txt"
REDIRECTS="redirects.txt"
HASHES="hashes.json"
REGISTRY="registry.json"

log() { echo "$*" >&2; }

graphql_query() {
  local query="$1" attempt=0 resp

  while ((attempt < MAX_RETRIES)); do
    if resp=$(gh api graphql -f query="$query" 2>/dev/null); then
      echo "$resp"
      return 0
    fi
    attempt=$((attempt + 1))
    ((attempt < MAX_RETRIES)) && log "    Retry ${attempt}/${MAX_RETRIES}..." && sleep $((attempt * 5))
  done

  log "    Failed after ${MAX_RETRIES} retries."
  jq -r '.errors[]? | "    \(.type): \(.message)"' <<<"${resp:-}" 2>/dev/null | while IFS= read -r line; do log "$line"; done
  return 1
}

fetch_repo_urls() {
  log "Fetching repos..."
  mapfile -t repos < <(curl -sfL "$API_URL" | jq -r '.repos[]')
  local total=${#repos[@]}
  local batches=$(((total + BATCH - 1) / BATCH))
  log "Found ${total} repos, ${batches} batches"

  >"$URLS"
  >"$REDIRECTS"

  log "Querying GraphQL..."
  for ((i = 0; i < total; i += BATCH)); do
    log "  Batch $((i / BATCH + 1))/${batches}..."

    local query="{"
    for ((j = i; j < i + BATCH && j < total; j++)); do
      IFS='/' read -r owner name <<<"${repos[$j]}"
      query+="r${j}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } }"
    done
    query+="}"

    local resp
    resp=$(graphql_query "$query") || continue

    local batch_out
    batch_out=$(jq -r '
      (.errors // []) | map({key: .path[0], message: .message}) | from_entries as $errs |
      .data | to_entries[] |
      if .value == null then
        "ERR\t\(.key[1:])\t\($errs[.key] // "Unknown error")"
      else
        "OK\t\(.key[1:])\t\(.value.nameWithOwner)\t\(.value.defaultBranchRef.target.oid)"
      end
    ' <<<"$resp" 2>/dev/null) || continue

    while IFS=$'\t' read -r status idx name rev; do
      if [[ "$status" == "OK" ]]; then
        local input="${repos[$idx]}"
        echo "https://github.com/${name}/archive/${rev}.tar.gz" >>"$URLS"
        [[ "$name" != "$input" ]] && echo "${input} -> ${name}" >>"$REDIRECTS"
      else
        log "    Error: ${repos[$idx]} — ${name}"
      fi
    done <<<"$batch_out"
  done

  log "Got $(wc -l <"$URLS") refs, $(wc -l <"$REDIRECTS") redirects"
}

fetch_hashes() {
  log "Fetching hashes..."
  nix run github:z1-0/nix-bulkfetch-url -- --unpack --json <"$URLS" >"$HASHES"
}

generate_registry() {
  log "Generate registry..."
  jq -n \
    --slurpfile hashes "$HASHES" \
    --rawfile redirects "$REDIRECTS" '
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
  ' >"$REGISTRY"
  log "Done: ${REGISTRY}"
}

fetch_repo_urls
fetch_hashes
generate_registry
