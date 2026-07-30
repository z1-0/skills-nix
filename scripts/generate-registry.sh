#!/usr/bin/env bash
set -euo pipefail

API_URL="https://skills-nix.vercel.app/api/repos.json"
BATCH=50

URLS="urls.txt"
REDIRECTS="redirects.txt"
HASHES="hashes.json"
REGISTRY="registry.json"
FAILED="failed.txt"

log() { echo "$*" >&2; }

graphql_query() {
  local query="$1" resp
  resp=$(gh api graphql -f query="$query" 2>/dev/null) || true
  if jq -e '.data' <<<"${resp:-null}" >/dev/null 2>&1; then
    echo "$resp"
    return 0
  fi
  return 1
}

parse_repo_response() {
  local resp="$1"
  jq -r '
    (.errors // [] | map({key: .path[0], value: .message}) | from_entries) as $errs |
    .data | to_entries[] |
    ($errs[.key] // "Unknown error") as $msg |
    if .value == null then
      "ERR\t\(.key[1:])\t\($msg)"
    else
      "OK\t\(.key[1:])\t\(.value.nameWithOwner)\t\(.value.defaultBranchRef.target.oid)"
    end
  ' <<<"$resp"
}

handle_batch_results() {
  local batch_out="$1"
  local status idx name rev input

  while IFS=$'\t' read -r status idx name rev; do
    if [[ "$status" == "OK" ]]; then
      input="${repos[$idx]}"
      echo "https://github.com/${name}/archive/${rev}.tar.gz" >>"$URLS"
      if [[ "$name" != "$input" ]]; then
        echo "${input} -> ${name}" >>"$REDIRECTS"
      fi
    else
      log "  ${repos[$idx]} - ${name}"
      echo "${repos[$idx]}" >>"$FAILED"
    fi
  done <<<"$batch_out"
}

process_batch() {
  local i="$1" query="$2" resp batch_out
  resp=$(graphql_query "$query") || return 1
  batch_out=$(parse_repo_response "$resp") || return 1
  handle_batch_results "$batch_out"
}

# ---- Main ----
log "Fetching repos..."
mapfile -t repos < <(curl -sfL --max-time 30 "$API_URL" | jq -r '.repos[]')

total=${#repos[@]}
batches=$(((total + BATCH - 1) / BATCH))
log "Found ${total} repos, ${batches} batches"

>"$URLS"
>"$REDIRECTS"
>"$FAILED"

for ((i = 0; i < total; i += BATCH)); do
  log "  Batch $((i / BATCH + 1))/${batches}..."

  query="{"
  for ((j = i; j < i + BATCH && j < total; j++)); do
    IFS='/' read -r owner name <<<"${repos[$j]}"
    query+="r${j}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } }"
  done
  query+="}"

  if ! process_batch "$i" "$query"; then
    log "    Batch $((i / BATCH + 1))/${batches} failed (API error)"
    for ((j = i; j < i + BATCH && j < total; j++)); do
      echo "${repos[$j]}" >>"$FAILED"
    done
  fi
done

got_refs=$(wc -l <"$URLS")
got_failed=$(wc -l <"$FAILED")
log "Got ${got_refs} refs, $(wc -l <"$REDIRECTS") redirects"
if ((got_failed > 0)); then
  log "WARNING: ${got_failed} repos failed"
fi

if [[ ! -s "$URLS" ]]; then
  log "ERROR: No URLs fetched, aborting"
  exit 1
fi

log "Fetching hashes..."
nix run github:z1-0/nix-bulkfetch-url -- --unpack --json <"$URLS" >"$HASHES"

log "Generate registry..."
jq -n \
  --slurpfile hashes "$HASHES" \
  --rawfile redirects "$REDIRECTS" \
  '
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
) | (to_entries | map(.key = (.key | ascii_downcase)) | sort_by(.key)) as $repos | {
  updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
  count: ($repos | length),
  repos: ($repos | from_entries)
}
' >"$REGISTRY"
log "Done: ${REGISTRY}"
