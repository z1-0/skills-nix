{ lib, pkgs }:

let
  registryJson = builtins.fromJSON (builtins.readFile ../registry.json);

  parse =
    skill:
    let
      atParts = lib.splitString "@" skill;
      hasAt = builtins.length atParts > 1;
      repoRef = builtins.elemAt atParts 0;
      specificName = if hasAt then builtins.elemAt atParts 1 else null;
      parts = lib.splitString "/" repoRef;
      owner = lib.toLower (builtins.elemAt parts 0);
      repo = lib.toLower (builtins.elemAt parts 1);
      name = if specificName != null then specificName else repo;
      registryKey = "${owner}/${repo}";
    in
    if builtins.length parts != 2 then
      throw "Invalid skill format '${skill}': expected 'owner/repo' or 'owner/repo@skillName'"
    else
      {
        inherit owner repo name specificName registryKey;
      };

  getRegistryEntry =
    parsed:
    let
      entry = registryJson.repos.${parsed.registryKey} or null;
    in
    if entry == null then
      throw "Skill repo '${parsed.registryKey}' not found in registry"
    else
      entry;

  fetchRepo =
    parsed: entry:
    pkgs.fetchFromGitHub {
      owner = parsed.owner;
      repo = parsed.repo;
      rev = entry.rev;
      hash = entry.hash;
    };

  extractNameFromSKILL = defaultName: skillDir:
    let
      mdPath = "${skillDir}/SKILL.md";
      parts =
        if !builtins.pathExists mdPath then [ ] else lib.splitString "---" (builtins.readFile mdPath);
      fmLines =
        if builtins.length parts >= 3 then lib.splitString "\n" (builtins.elemAt parts 1) else [ ];
      nameLine = lib.findFirst (line: (builtins.match "[[:space:]]*name:.*" line) != null) null fmLines;
    in
    if nameLine == null then defaultName else
    let
      trimmed = builtins.head (builtins.match "[[:space:]]*name:[[:space:]]*(.*)" nameLine);
      unquoted =
        if lib.hasPrefix "\"" trimmed then
          builtins.head (builtins.match "\"([^\"]*)\".*" trimmed)
        else if lib.hasPrefix "'" trimmed then
          builtins.head (builtins.match "'([^']*)'.*" trimmed)
        else
          trimmed;
    in
    if unquoted != "" then unquoted else defaultName;

  findSkillsInDir =
    dir: depth:
    let
      entries = builtins.readDir dir;
      names = builtins.attrNames (lib.filterAttrs (n: v: v == "directory") entries);
      checkDir =
        name:
        let
          subPath = "${dir}/${name}";
          subEntries = builtins.readDir subPath;
          subdirs = builtins.attrNames (lib.filterAttrs (n: v: v == "directory") subEntries);
        in
        if builtins.hasAttr "SKILL.md" subEntries then
          [{ inherit name; path = name; }]
        else if depth != 0 && depth != 1 && builtins.length subdirs > 0 then
          map (s: s // { path = "${name}/${s.path}"; }) (
            findSkillsInDir subPath (if depth == -1 then -1 else depth - 1)
          )
        else
          [ ];
    in
    lib.concatMap checkDir names;

  discoverSkills =
    parsed: repoPath: depth:
    let
      flatSkills = findSkillsInDir repoPath 1;
      rootSkill =
        if builtins.pathExists "${repoPath}/SKILL.md" then
          [{ name = parsed.name; path = "."; }]
        else
          [ ];
      skillsDir = "${repoPath}/skills";
      searchDepth = if depth <= 0 then -1 else depth;
      nestedSkills =
        if builtins.pathExists skillsDir then
          map (s: s // { path = "skills/${s.path}"; }) (findSkillsInDir skillsDir searchDepth)
        else
          [ ];
      allSkills = flatSkills ++ nestedSkills ++ rootSkill;
    in
    if allSkills == [ ] then
      throw "No skills found in '${repoPath}'"
    else
      map (s: s // { name = extractNameFromSKILL s.name "${repoPath}/${s.path}"; }) allSkills;

  resolveSkill =
    depth: skill: resolvedDir:
    let
      parsed = parse skill;
      entry = getRegistryEntry parsed;
      repoPath = fetchRepo parsed entry;
      discovered = discoverSkills parsed repoPath depth;
      matched =
        if parsed.specificName != null then
          builtins.filter (s: s.name == parsed.specificName) discovered
        else
          discovered;
    in
    if parsed.specificName != null && matched == [ ] then
      throw "Skill '${parsed.specificName}' not found in '${parsed.registryKey}'"
    else
      map (s: {
        name = "${resolvedDir}/${s.name}";
        storePath = "${repoPath}/${s.path}";
        source = skill;
      }) matched;

  assertNoConflicts =
    entries:
    let
      getName = e: lib.last (lib.splitString "/" e.name);
      grouped = lib.foldl' (acc: e:
        let n = getName e;
        in acc // { ${n} = (acc.${n} or [ ]) ++ [ e ]; }
      ) { } entries;
      conflicts = lib.filterAttrs (_: g: builtins.length g > 1) grouped;
      formatConflict = { name, group }:
        "  \"${name}\" provided by:\n"
        + lib.concatMapStringsSep "\n" (e: "    - ${e.source}") group;
    in
    if conflicts == { } then
      entries
    else
      throw ''
        Conflicting skill names detected:

        ${lib.concatMapStringsSep "\n" formatConflict (lib.mapAttrsToList (name: group: { inherit name group; }) conflicts)}

        Fix: use owner/repo@skillName to disambiguate.
      '';

  buildAllFileEntries =
    install: depth: resolvedDir:
    assertNoConflicts (lib.concatMap (skill: resolveSkill depth skill resolvedDir) install);

in

{
  inherit buildAllFileEntries;
}
