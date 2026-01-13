{ lib, pkgs }:

let
  registryJson = builtins.fromJSON (builtins.readFile ../registry.json);

  parse =
    skill:
    let
      atParts = lib.splitString "@" skill;
      hasAt = builtins.length atParts > 1;
      repoRef = builtins.elemAt atParts 0;
      targetName = if hasAt then builtins.elemAt atParts 1 else null;
      parts = lib.splitString "/" repoRef;
      len = builtins.length parts;
      owner = lib.toLower (builtins.elemAt parts 0);
      repo = lib.toLower (builtins.elemAt parts 1);
      name = if targetName != null then targetName else repo;
      registryKey = "${owner}/${repo}";
    in
    if len != 2 then
      throw "Invalid skill format '${skill}': expected 'owner/repo' or 'owner/repo@skillName'"
    else
      {
        inherit
          owner
          repo
          name
          targetName
          registryKey
          ;
      };

  getRegistryEntry =
    parsed:
    let
      entry = registryJson.repos.${parsed.registryKey} or null;
    in
    if entry == null then
      throw "Skill repo '${parsed.registryKey}' not found in registry. See the registry.json file at the repo root for available repos."
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

  extractNameFromSKILL =
    defaultName: skillDir:
    let
      mdPath = "${skillDir}/SKILL.md";
      parts =
        if !builtins.pathExists mdPath then [ ] else lib.splitString "---" (builtins.readFile mdPath);
      fmLines =
        if builtins.length parts >= 3 then lib.splitString "\n" (builtins.elemAt parts 1) else [ ];
      nameLine = lib.findFirst (line: (builtins.match "[[:space:]]*name:.*" line) != null) null fmLines;
      extract =
        raw:
        let
          trimmed = builtins.head (builtins.match "[[:space:]]*name:[[:space:]]*(.*)" raw);
          unquoted = builtins.head (
            builtins.filter (x: x != null) (builtins.match "\"([^\"]*)\"|'([^']*)'|(.*)" trimmed)
          );
        in
        if unquoted != "" then unquoted else defaultName;
    in
    if nameLine != null then extract nameLine else defaultName;

  findSkillsInDir =
    dir: depth:
    let
      entries = builtins.readDir dir;
      dirs = lib.filterAttrs (n: v: v == "directory") entries;
      subdirs = lib.mapAttrsToList (name: path: {
        inherit name;
        path = name;
      }) dirs;
      checkDir =
        entry:
        let
          subEntries = builtins.readDir "${dir}/${entry.name}";
          nextDepth = if depth == -1 then -1 else depth - 1;
        in
        if builtins.hasAttr "SKILL.md" subEntries then
          [ entry ]
        else if
          (depth < 0 || depth > 1)
          && builtins.length (builtins.attrNames (lib.filterAttrs (n: v: v == "directory") subEntries)) > 0
        then
          map (s: s // { path = "${entry.path}/${s.path}"; }) (
            findSkillsInDir "${dir}/${entry.name}" nextDepth
          )
        else
          [ ];
    in
    lib.concatMap checkDir subdirs;

  discoverSkills =
    parsed: repoPath: depth:
    let
      flatSkills = findSkillsInDir repoPath 1;
      hasRootSkill = builtins.pathExists "${repoPath}/SKILL.md";
      rootSkill =
        if hasRootSkill then
          [
            {
              name = parsed.name;
              path = ".";
            }
          ]
        else
          [ ];
      skillsDir = "${repoPath}/skills";
      skillsDirExists = builtins.pathExists skillsDir;
      searchDepth = if depth <= 0 then -1 else depth;
      nestedSkills =
        if skillsDirExists then
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
        if parsed.targetName != null then
          builtins.filter (s: s.name == parsed.targetName) discovered
        else
          discovered;
    in
    if parsed.targetName != null && matched == [ ] then
      throw "Skill '${parsed.targetName}' not found in '${parsed.registryKey}'"
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
      grouped = lib.foldl' (
        acc: e:
        let
          n = getName e;
        in
        acc // { ${n} = (acc.${n} or [ ]) ++ [ e ]; }
      ) { } entries;
      conflicts = lib.filterAttrs (_: g: builtins.length g > 1) grouped;
    in
    if conflicts == { } then
      entries
    else
      let
        lines = lib.concatMapStringsSep "\n" (
          { name, group }:
          "  \"${name}\" provided by:\n" + lib.concatMapStringsSep "\n" (e: "    - ${e.source}") group
        ) (lib.mapAttrsToList (name: group: { inherit name group; }) conflicts);
      in
      throw ''
        Conflicting skill names detected:

        ${lines}

        Fix: use owner/repo@skillName to disambiguate.
      '';

  buildAllFileEntries =
    install: depth: resolvedDir:
    assertNoConflicts (lib.concatMap (skill: resolveSkill depth skill resolvedDir) install);

in

{
  inherit
    buildAllFileEntries
    ;
}
