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