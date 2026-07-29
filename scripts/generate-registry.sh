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

query_repo() {
  local owner="$1" name="$2" idx="$3"
  local query="{ r${idx}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } } }"
  local resp
  resp=$(graphql_query "$query") || return 1
  jq -r '
    (.errors // [] | map({key: .path[0], value: .message}) | from_entries) as $errs |
    .data | to_entries[] |
    if .value == null then
      "ERR\t\(.key[1:])\t\($errs[.key] // \"Unknown error\")"
    else
      "OK\t\(.key[1:])\t\(.value.nameWithOwner)\t\(.value.defaultBranchRef.target.oid)"
    end
  ' <<<"$resp" 2>/dev/null || return 1
}

fetch_repo_urls() {
  log "Fetching repos..."
  mapfile -t repos < <(curl -sfL "$API_URL" | jq -r '.repos[]')
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

    local resp
    if resp=$(graphql_query "$query"); then
      local batch_out
      batch_out=$(jq -r '
        (.errors // [] | map({key: .path[0], value: .message}) | from_entries) as $errs |
        .data | to_entries[] |
        if .value == null then
          "ERR\t\(.key[1:])\t\($errs[.key] // \"Unknown error\")"
        else
          "OK\t\(.key[1:])\t\(.value.nameWithOwner)\t\(.value.defaultBranchRef.target.oid)"
        end
      ' <<<"$resp" 2>/dev/null) || true

      while IFS=$'\t' read -r status idx name rev; do
        if [[ "$status" == "OK" ]]; then
          local input="${repos[$idx]}"
          echo "https://github.com/${name}/archive/${rev}.tar.gz" >>"$URLS"
          [[ "$name" != "$input" ]] && echo "${input} -> ${name}" >>"$REDIRECTS"
        else
          log "    Error: ${repos[$idx]} - ${name}"
          echo "${repos[$idx]}" >>"$FAILED"
        fi
      done <<<"$batch_out"
    else
      log "    Batch failed, retrying repos individually..."
      for ((j = i; j < i + BATCH && j < total; j++)); do
        local repo="${repos[$j]}"
        local owner name
        IFS='/' read -r owner name <<<"$repo"

        local result
        result=$(query_repo "$owner" "$name" "$j") && {
          while IFS=$'\t' read -r status idx name rev; do
            if [[ "$status" == "OK" ]]; then
              local input="${repos[$idx]}"
              echo "https://github.com/${name}/archive/${rev}.tar.gz" >>"$URLS"
              [[ "$name" != "$input" ]] && echo "${input} -> ${name}" >>"$REDIRECTS"
            else
              log "      Error: ${repo} - ${name}"
              echo "${repo}" >>"$FAILED"
            fi
          done <<<"$result"
        } || {
          log "      Failed: ${repo}"
          echo "${repo}" >>"$FAILED"
        }
      done
    fi
  done

  local got_refs got_redirects got_failed
  got_refs=$(wc -l <"$URLS")
  got_redirects=$(wc -l <"$REDIRECTS")
  got_failed=$(wc -l <"$FAILED")
  log "Got ${got_refs} refs, ${got_redirects} redirects"
  if ((got_failed > 0)); then
    log "WARNING: ${got_failed} repos failed, see ${FAILED}"
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
    ) | (to_entries | map(.key = (.key | ascii_downcase)) | sort_by(.key)) as $repos | {
      updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      count: ($repos | length),
      repos: ($repos | from_entries)
    }
  ' >"$REGISTRY"
  log "Done: ${REGISTRY}"
}

fetch_repo_urls
fetch_hashes
generate_registry
