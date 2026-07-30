#!/usr/bin/env bash
set -euo pipefail

API_URL="https://skills-nix.vercel.app/api/repos.json"
BATCH=8
MAX_RETRIES=3

URLS="urls.txt"
REDIRECTS="redirects.txt"
HASHES="hashes.json"
REGISTRY="registry.json"
FAILED="failed.txt"

log() { echo "$*" >&2; }

graphql_query() {
  local query="$1" attempt=0 resp

  while ((attempt < MAX_RETRIES)); do
    resp=$(gh api graphql -f query="$query" 2>/dev/null) || true

    if jq -e '[.data[] | select(. != null)] | length > 0' <<<"${resp:-null}" >/dev/null 2>&1; then
      echo "$resp"
      return 0
    fi

    attempt=$((attempt + 1))
    ((attempt < MAX_RETRIES)) && log "    Retry ${attempt}/${MAX_RETRIES}..." && sleep $((attempt * 5))
  done

  log "    Failed after ${MAX_RETRIES} attempts."
  local errors
  errors=$(jq -r '.errors[]? | "    \(.type): \(.message)"' <<<"${resp:-}" 2>/dev/null)
  [[ -n "$errors" ]] && log "$errors"
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
  local prefix="$1" batch_out="$2"
  local status idx name rev input

  while IFS=$'\t' read -r status idx name rev; do
    if [[ "$status" == "OK" ]]; then
      input="${repos[$idx]}"
      echo "https://github.com/${name}/archive/${rev}.tar.gz" >>"$URLS"
      [[ "$name" != "$input" ]] && echo "${input} -> ${name}" >>"$REDIRECTS"
    else
      log "${prefix}Error: ${repos[$idx]} - ${name}"
      echo "${repos[$idx]}" >>"$FAILED"
    fi
  done <<<"$batch_out"
}

query_repo() {
  local owner="$1" name="$2" idx="$3"
  local query="{ r${idx}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } } }"
  local resp parsed
  resp=$(graphql_query "$query") || return 1
  parsed=$(parse_repo_response "$resp") || return 1
  echo "$parsed"
}

process_batch() {
  local i="$1" query="$2" total="$3"
  local resp batch_out

  resp=$(graphql_query "$query") || return 1
  batch_out=$(parse_repo_response "$resp") || return 1

  handle_batch_results "    " "$batch_out"
}

retry_batch_individually() {
  local i="$1" total_batch="$2"
  local j repo owner name result

  log "    Batch failed, retrying repos individually..."
  for ((j = i; j < i + total_batch && j < total; j++)); do
    repo="${repos[$j]}"
    IFS='/' read -r owner name <<<"$repo"

    if result=$(query_repo "$owner" "$name" "$j"); then
      handle_batch_results "      " "$result"
    else
      log "      Failed: ${repo}"
      echo "${repo}" >>"$FAILED"
    fi
  done
}

fetch_repo_urls() {
  log "Fetching repos..."
  mapfile -t repos < <(curl -sfL --max-time 30 "$API_URL" | jq -r '.repos[]')
  local total=${#repos[@]}
  local batches=$(((total + BATCH - 1) / BATCH))
  log "Found ${total} repos, ${batches} batches"

  >"$URLS"
  >"$REDIRECTS"
  >"$FAILED"

  log "Querying GraphQL..."
  for ((i = 0; i < total; i += BATCH)); do
    log "  Batch $((i / BATCH + 1))/${batches}..."

    local query="{"
    for ((j = i; j < i + BATCH && j < total; j++)); do
      IFS='/' read -r owner name <<<"${repos[$j]}"
      query+="r${j}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } }"
    done
    query+="}"

    local batch_size=$((i + BATCH < total ? BATCH : total - i))

    if ! process_batch "$i" "$query" "$batch_size"; then
      if ! retry_batch_individually "$i" "$batch_size"; then
        log "    Still failing after individual retry"
      fi
    fi
  done

  local got_refs got_redirects got_failed
  got_refs=$(wc -l <"$URLS")
  got_redirects=$(wc -l <"$REDIRECTS")
  got_failed=$(wc -l <"$FAILED")
  log "Got ${got_refs} refs, ${got_redirects} redirects"
  if ((got_failed > 0)); then
    log "WARNING: ${got_failed} repos failed:"
    while IFS= read -r line; do log "  - ${line}"; done <"$FAILED"
  fi
}

fetch_hashes() {
  log "Fetching hashes..."
  nix run github:z1-0/nix-bulkfetch-url -- --unpack --json <"$URLS" >"$HASHES"
}

generate_registry() {
  log "Generate registry..."
  jq -n \
    --slurpfile hashes "$HASHES" \
    --rawfile redirects "$REDIRECTS" \
    --from-file "$(dirname "${BASH_SOURCE[0]}")/generate-registry.jq" \
    >"$REGISTRY"
  log "Done: ${REGISTRY}"
}

fetch_repo_urls

if [[ ! -s "$URLS" ]]; then
  log "ERROR: No URLs fetched, aborting"
  exit 1
fi

fetch_hashes
generate_registry
