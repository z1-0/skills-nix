#!/usr/bin/env bash
set -euo pipefail

SKILLS_SITEMAP_INDEX="https://www.skills.sh/sitemap.xml"
OWNERS_SITEMAP="https://www.skills.sh/sitemap-owners.xml"
BATCH=150   # tested: up to ~175 distinct repos per query works, >=190 returns 502/504

# File formats:
#   urls.txt        text/uri-list (RFC 2483) — stdin contract of nix-bulkfetch-url
#   hashes.json     JSON array              — stdout contract of nix-bulkfetch-url
#   registry.json   JSON document           — final artifact, parsed in one pass
#   *.jsonl         JSON Lines              — line-oriented intermediate state
URLS="urls.txt"
REDIRECTS="redirects.jsonl"
HASHES="hashes.json"
REGISTRY="registry.json"
FAILED="failed.jsonl"
REUSED="reused.jsonl"
PENDING="pending.jsonl"

log() { echo "$*" >&2; }

DRY_RUN=0
RESOLVE_ONLY=0
LIMIT=0
while (($# > 0)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --resolve-only) RESOLVE_ONLY=1 ;;
    --limit) LIMIT="${2:?--limit needs a number}"; shift ;;
    --limit=*) LIMIT="${1#--limit=}" ;;
    *)
      log "Unknown argument: $1"
      exit 2
      ;;
  esac
  shift
done

LAST_GQL_ERROR=""

graphql_query() {
  local query="$1" resp err
  err=$(mktemp)
  resp=$(gh api graphql -f query="$query" 2>"$err") || true
  if jq -e '.data' <<<"${resp:-null}" >/dev/null 2>&1; then
    rm -f "$err"
    echo "$resp"
    return 0
  fi
  LAST_GQL_ERROR=$(tr -d '\n' <"$err" | head -c 300)
  rm -f "$err"
  return 1
}

# Retry transient API failures (502/504/timeouts) with backoff.
fetch_batch() {
  local query="$1" attempt
  for attempt in 1 2 3; do
    if resp=$(graphql_query "$query"); then
      return 0
    fi
    log "    attempt ${attempt}/3 failed${LAST_GQL_ERROR:+: ${LAST_GQL_ERROR}}"
    if ((attempt < 3)); then
      sleep $((attempt * 2))
    fi
  done
  return 1
}

# Resolve one chunk of repos. Failed chunks are queued in RETRY_QUEUE instead of
# being dropped, so the caller can retry them with smaller queries.
RETRY_QUEUE=()

resolve_chunk() {
  local -a chunk=("$@")
  local n=${#chunk[@]} k owner name query inputs resp decided
  ((n == 0)) && return 0

  query="{"
  for ((k = 0; k < n; k++)); do
    IFS='/' read -r owner name <<<"${chunk[$k]}"
    query+="r${k}: repository(owner: \"${owner}\", name: \"${name}\") { nameWithOwner defaultBranchRef { target { oid } } }"
  done
  query+="}"

  inputs=$(printf '%s\n' "${chunk[@]}" | jq -Rs 'split("\n") | map(select(length > 0))')

  if ! fetch_batch "$query"; then
    RETRY_QUEUE+=("${chunk[@]}")
    return 1
  fi

  decided=$(jq -c --argjson inputs "$inputs" --slurpfile cache "$CACHE" "$DECIDE_JQ" <<<"$resp")

  jq -c 'select(.status == "reuse")' <<<"$decided" >>"$REUSED"
  jq -c 'select(.status == "hash")' <<<"$decided" >>"$PENDING"
  jq -c 'select(.status == "error")' <<<"$decided" >>"$FAILED"
  jq -c 'select(.status != "error" and .input != .key)' <<<"$decided" >>"$REDIRECTS"
}

# Turn one GraphQL batch response into JSON Lines decisions:
#   {key, name, input, rev, status:"reuse", hash}
#   {key, name, input, rev, status:"hash",  url}
#   {key, input, status:"error", error}
# Reuse happens when the resolved commit matches the cached one.
DECIDE_JQ='
  . as $resp |
  ($resp.errors // [] | map({ key: .path[0], value: .message }) | from_entries) as $errs |
  ($cache[0].repos // {}) as $c |
  $resp.data | to_entries[] |
  (.key[1:] | tonumber) as $idx |
  ($inputs[$idx]) as $input |
  .value as $v |
  if $v == null then
    { key: ($input | ascii_downcase), input: $input, status: "error",
      error: ($errs[.key] // "unknown error") }
  else
    ($v.nameWithOwner | ascii_downcase) as $key |
    ($v.defaultBranchRef.target.oid) as $rev |
    if ($c[$key].rev? // "") == $rev then
      { key: $key, name: $v.nameWithOwner, input: $input, rev: $rev,
        status: "reuse", hash: $c[$key].hash }
    else
      { key: $key, name: $v.nameWithOwner, input: $input, rev: $rev,
        status: "hash",
        url: "https://github.com/\($v.nameWithOwner)/archive/\($rev).tar.gz" }
    end
  end
'

# Download a URL with retries; a transient CDN blip should not cost a whole week.
fetch_url() {
  local url="$1" attempt
  for attempt in 1 2 3; do
    if curl -fsSL --max-time 120 "$url"; then
      return 0
    fi
    log "    download attempt ${attempt}/3 failed: ${url}"
    if ((attempt < 3)); then
      sleep $((attempt * 2))
    fi
  done
  return 1
}

discover_skill_sitemaps() {
  fetch_url "$SKILLS_SITEMAP_INDEX" \
    | grep -oE 'https://www\.skills\.sh/sitemap-skills-[0-9]+\.xml' \
    | sort -u
}

# Extract "<owner>/<repo>" from a sitemap URL list on stdin.
# - sitemap-owners.xml holds both "/<owner>" and "/<owner>/<repo>" entries;
#   only the 2-segment ones are repos.
# - sitemap-skills-*.xml hold "/<owner>/<repo>/<skill>"; the first two
#   segments give the repo.
urls_to_repos() {
  local segs="$1"
  sed -E 's#</?loc>##g' \
    | sed -E 's#https?://(www\.)?skills\.sh/##' \
    | awk -F/ -v n="$segs" 'NF==n' \
    | cut -d/ -f1-2 \
    | grep -vE '^(site|packs|topics|agents|audits|official|docs|search|hot|trending|picks)/' \
    | tr 'A-Z' 'a-z'
}

# Repo list = sitemap-owners repo pages (repo-level popularity floor)
#             ∪ sitemap-skills repos (skill-level floor).
# The owners source is ~4.4x larger; the skills source is kept as a cheap
# safety net in case the two sitemaps are generated out of sync.
collect_repos_from_sitemaps() {
  local skill_sitemaps="$1" tmp raw sm
  tmp=$(mktemp)
  raw=$(mktemp)

  log "  ${OWNERS_SITEMAP}"
  if ! fetch_url "$OWNERS_SITEMAP" >"$raw"; then
    log "ERROR: cannot download ${OWNERS_SITEMAP}"
    rm -f "$tmp" "$raw"
    return 1
  fi
  grep -oE '<loc>[^<]+</loc>' "$raw" | urls_to_repos 2 >>"$tmp"

  while read -r sm; do
    [[ -z "$sm" ]] && continue
    log "  ${sm}"
    if ! fetch_url "$sm" >"$raw"; then
      log "WARNING: cannot download ${sm}, continuing without it"
      continue
    fi
    grep -oE '<loc>[^<]+</loc>' "$raw" | urls_to_repos 3 >>"$tmp"
  done <<<"$skill_sitemaps"

  sort -u "$tmp"
  rm -f "$tmp" "$raw"
}

# ---- Main ----
log "Discovering skill sitemaps from ${SKILLS_SITEMAP_INDEX}..."
SKILL_SITEMAPS=$(discover_skill_sitemaps)

if [[ -z "$SKILL_SITEMAPS" ]]; then
  log "ERROR: no sitemap-skills-*.xml found in index"
  exit 1
fi

log "Fetching repos from sitemap-owners + skill sitemaps..."
repo_list=$(collect_repos_from_sitemaps "$SKILL_SITEMAPS") || {
  log "ERROR: repo collection failed, keeping the current registry untouched"
  exit 1
}
if [[ -z "$repo_list" ]]; then
  log "ERROR: repo list is empty, keeping the current registry untouched"
  exit 1
fi
mapfile -t repos <<<"$repo_list"

total=${#repos[@]}
if ((LIMIT > 0 && LIMIT < total)); then
  log "Limiting to ${LIMIT} repos (test mode)"
  repos=("${repos[@]:0:LIMIT}")
  total=$LIMIT
fi
batches=$(((total + BATCH - 1) / BATCH))
log "Found ${total} repos, ${batches} batches"

if ((total == 0)); then
  log "ERROR: no repos collected"
  exit 1
fi

if ((DRY_RUN == 1)); then
  log "Dry run: repo collection OK (${total} repos), nothing resolved or hashed"
  printf '%s\n' "${repos[@]}"
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  log "ERROR: gh is not authenticated (export GH_TOKEN or run 'gh auth login')"
  exit 1
fi

# Hash cache = the previous registry. On a cold start there is nothing to reuse,
# so feed the decision step an empty cache instead of failing on a missing file.
CACHE="$REGISTRY"
CACHE_TMP=""
if [[ ! -s "$REGISTRY" ]]; then
  CACHE_TMP=$(mktemp)
  echo '{"repos":{}}' >"$CACHE_TMP"
  CACHE="$CACHE_TMP"
  trap '[[ -n "$CACHE_TMP" ]] && rm -f "$CACHE_TMP"' EXIT
  log "No existing ${REGISTRY}, every repo will be hashed"
else
  log "Loaded hash cache from ${REGISTRY}"
fi

: >"$URLS"
: >"$REDIRECTS"
: >"$FAILED"
: >"$REUSED"
: >"$PENDING"

for ((i = 0; i < total; i += BATCH)); do
  log "  Batch $((i / BATCH + 1))/${batches}..."
  resolve_chunk "${repos[@]:i:BATCH}" || true
done

# Retries: a failed batch is transient on GitHub's side, so re-ask in smaller
# chunks (10, then 1) instead of dropping every repo it contained.
for retry_size in 10 1; do
  ((${#RETRY_QUEUE[@]} == 0)) && break
  current=("${RETRY_QUEUE[@]}")
  RETRY_QUEUE=()
  log "  Retrying ${#current[@]} repos, ${retry_size} per query"
  for ((r = 0; r < ${#current[@]}; r += retry_size)); do
    resolve_chunk "${current[@]:r:retry_size}" || true
  done
done

if ((${#RETRY_QUEUE[@]} > 0)); then
  log "WARNING: ${#RETRY_QUEUE[@]} repo(s) unresolved after retries, dropped this run"
  printf '%s\n' "${RETRY_QUEUE[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' \
    | jq -c '.[] | . as $i | { key: ($i | ascii_downcase), input: $i, status: "error", error: "graphql batch failed after retries" }' \
      >>"$FAILED"
fi

got_reused=$(wc -l <"$REUSED")
got_pending=$(wc -l <"$PENDING")
got_failed=$(wc -l <"$FAILED")
log "Resolved: ${got_reused} reused, ${got_pending} to hash, ${got_failed} failed, $(wc -l <"$REDIRECTS") redirects"

# Two entries can collapse onto the same canonical name only when a repo was
# renamed and both the old and the new name are in the sitemap. Harmless (the
# merge dedupes by key) but worth surfacing, since it means duplicate hashing.
dups=$(cat "$REUSED" "$PENDING" | jq -s 'group_by(.key) | map(select(length > 1)) | length')
if [[ "$dups" != "0" ]]; then
  log "WARNING: ${dups} canonical name(s) resolved more than once (renamed repos), deduped on merge"
fi

if ((RESOLVE_ONLY == 1)); then
  log "Resolve only: nothing hashed"
  exit 0
fi

if ((got_reused + got_pending == 0)); then
  log "ERROR: nothing resolved, aborting"
  exit 1
fi

if ((got_pending > 0)); then
  jq -r '.url' "$PENDING" >"$URLS"
  log "Nix store before hashing: $(du -sh /nix/store 2>/dev/null | cut -f1 || echo n/a)"
  log "Fetching hashes for ${got_pending} repos..."
  nix run github:z1-0/nix-bulkfetch-url -- --unpack --json --timeout 3600 <"$URLS" >"$HASHES"
  log "Nix store after hashing: $(du -sh /nix/store 2>/dev/null | cut -f1 || echo n/a)"
else
  log "All repos unchanged, skipping hash step"
  echo '[]' >"$HASHES"
fi

log "Generate registry..."
jq -n \
  --slurpfile hashes "$HASHES" \
  --slurpfile reused "$REUSED" \
  --slurpfile pending "$PENDING" \
  '
($hashes[0] // [] | map({ key: .url, value: .hash }) | from_entries) as $byUrl |
[
  ($reused[] | { key: .key, value: { rev: .rev, hash: .hash } }),
  ($pending[] | . as $p | { key: $p.key, value: { rev: $p.rev, hash: ($byUrl[$p.url] // "") } })
] as $entries |
([$entries[] | select(.value.hash == "")] | length) as $missing |
if $missing > 0 then
  error("missing hash for \($missing) repos")
else
  ($entries | sort_by(.key) | from_entries) as $repos |
  { updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), count: ($repos | length), repos: $repos }
end
' >"${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"

count=$(jq -r '.count' "$REGISTRY")
sed -i -E "s/(<!--REPO_COUNT-->)[0-9]+(<!--\/REPO_COUNT-->)/\1${count}\2/" README.md
log "Done: ${REGISTRY} (${count} repos: ${got_reused} reused, ${got_pending} hashed)"
