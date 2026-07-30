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
  local query="$1"
  local resp
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
  local prefix="$1" batch_out="$2"
  local status idx name rev input

  while IFS=$'\t' read -r status idx name rev; do
    if [[ "$status" == "OK" ]]; then
      input="${repos[$idx]}"
      echo "https://github.com/${name}/archive/${rev}.tar.gz" >>"$URLS"
      if [[ "$name" != "$input" ]]; then
        echo "${input} -> ${name}" >>"$REDIRECTS"
      fi
    else
      log "${prefix}${repos[$idx]} - ${name}"
      echo "${repos[$idx]}" >>"${FAILED}.tmp"
    fi
  done <<<"$batch_out"
  return 0
}

process_batch() {
  local i="$1" query="$2"
  local resp batch_out

  if ! resp=$(graphql_query "$query"); then
    return 1
  fi

  batch_out=$(parse_repo_response "$resp") || return 1
  handle_batch_results "    " "$batch_out"
}

process_repo_list() {
  local pass="$1" src="$2"
  local -a repos

  if [[ "$pass" == "1" ]]; then
    log "Fetching repos..."
    mapfile -t repos < <(curl -sfL --max-time 30 "$src" | jq -r '.repos[]')
  else
    log "Retrying failed repos..."
    mapfile -t repos <"$src"
  fi

  local total=${#repos[@]}
  if ((total == 0)); then return 0; fi

  local batches=$(((total + BATCH - 1) / BATCH))
  log "Found ${total} repos, ${batches} batches (pass ${pass})"

  >"${FAILED}.tmp"

  for ((i = 0; i < total; i += BATCH)); do
    log "  Batch $((i / BATCH + 1))/${batches}..."

    local query="{"
    for ((j = i; j < i + BATCH && j < total; j++)); do
      IFS='/' read -r owner name <<<"${repos[$j]}"
      query+="r${j}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } }"
    done
    query+="}"

    if ! process_batch "$i" "$query"; then
      log "    Batch $((i / BATCH + 1))/${batches} failed, marking all for retry"
      for ((j = i; j < i + BATCH && j < total; j++)); do
        echo "${repos[$j]}" >>"${FAILED}.tmp"
      done
    fi
  done

  mv "${FAILED}.tmp" "$FAILED"

  local got_refs got_redirects got_failed
  got_refs=$(wc -l <"$URLS")
  got_redirects=$(wc -l <"$REDIRECTS")
  got_failed=$(wc -l <"$FAILED")
  log "Pass ${pass}: got ${got_refs} refs, ${got_redirects} redirects"
  if ((got_failed > 0)); then
    log "Pass ${pass}: ${got_failed} repos failed"
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

# ---- Main ----
>"$URLS"
>"$REDIRECTS"
>"$FAILED"

process_repo_list 1 "$API_URL"

if [[ -s "$FAILED" ]]; then
  prev=$(wc -l <"$FAILED")
  process_repo_list 2 "$FAILED"
  now=$(wc -l <"$FAILED")
  log "Recovered $((prev - now)) of ${prev} failed repos"
fi

if [[ ! -s "$URLS" ]]; then
  log "ERROR: No URLs fetched, aborting"
  exit 1
fi

fetch_hashes
generate_registry
