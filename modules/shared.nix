{ lib, pkgs }:

let
  registryJson = builtins.fromJSON (builtins.readFile ../registry.json);

  parseSkill =
    skill:
    let
      parts = lib.splitString "/" skill;
      len = builtins.length parts;
      owner = lib.toLower (builtins.elemAt parts 0);
      repo = lib.toLower (builtins.elemAt parts 1);
      pathParts = lib.drop 2 parts;
      path = if pathParts != [ ] then lib.concatStringsSep "/" pathParts else null;
      name = if path != null then lib.last (lib.splitString "/" path) else repo;
      registryKey = "${owner}/${repo}";
    in
    if len < 2 then
      throw "Invalid skill format '${skill}': expected 'owner/repo' or 'owner/repo/path'"
    else
      {
        inherit
          owner
          repo
          name
          path
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

  readSkillName =
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
      shouldRecurse = depth == -1 || depth > 0;
      nextDepth = if depth == -1 then -1 else depth - 1;
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
        in
        if builtins.hasAttr "SKILL.md" subEntries then
          [ entry ]
        else if
          shouldRecurse
          && nextDepth != 0
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
      throw "No skills found in '${parsed.registryKey}' (${repoPath}) - no SKILL.md files discovered"
    else
      let
        withNames = map (s: s // { name = readSkillName s.name "${repoPath}/${s.path}"; }) allSkills;
      in
      withNames;

  processEntry =
    cfg: skill: resolvedDir:
    let
      parsed = parseSkill skill;
      entry = getRegistryEntry parsed;
      repoPath = fetchRepo parsed entry;
    in
    if parsed.path != null then
      let
        candidates = [
          "${repoPath}/skills/${parsed.path}"
          "${repoPath}/${parsed.path}"
        ];
        validCandidates = builtins.filter (p: builtins.pathExists "${p}/SKILL.md") candidates;
      in
      if validCandidates == [ ] then
        throw "Skill '${parsed.path}' not found in '${skill}'"
      else
        let
          skillSource = builtins.head validCandidates;
          skillName = readSkillName parsed.name skillSource;
        in
        [
          {
            name = "${resolvedDir}/${skillName}";
            storePath = skillSource;
            source = skill;
          }
        ]
    else
      let
        discovered = discoverSkills parsed repoPath cfg.depth;
      in
      map (s: {
        name = "${resolvedDir}/${s.name}";
        storePath = "${repoPath}/${s.path}";
        source = skill;
      }) discovered;

  detectConflicts =
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
        lines = lib.concatStringsSep "\n" (
          lib.flatten (
            lib.mapAttrsToList (
              name: group:
              [
                "  \"${name}\" fourni par :"
              ]
              ++ map (e: "    - ${e.source}") group
            ) conflicts
          )
        );
      in
      throw ''
        Conflits de noms de skills détectés :

        ${lines}

        Solution : utilisez un chemin explicite (owner/repo/path) pour désambiguïser.
      '';

  buildAllFileEntries =
    cfg: resolvedDir:
    detectConflicts (lib.concatMap (skill: processEntry cfg skill resolvedDir) cfg.install);

  # Generate activation script for NixOS/darwin (creates symlinks + cleans orphans)
  # resolvedDir must be an absolute path; ~ is only resolved by home-manager at Nix eval time
  mkActivationScript =
    cfg: entries: resolvedDir:
    let
      expectedPaths = map (e: e.name) entries;
    in
    ''
      mkdir -p '${resolvedDir}'
    ''
    + lib.concatStringsSep "\n" (
      map (e: ''
        mkdir -p "$(dirname '${e.name}')"
        ln -sfn '${e.storePath}' '${e.name}'
      '') entries
    )
    + lib.optionalString (entries != [ ]) ''
      if [ -d '${resolvedDir}' ]; then
        for entry in '${resolvedDir}'/*; do
          [ -L "$entry" ] || continue
          case " ${lib.concatStringsSep " " expectedPaths} " in
            *" $entry "* ) ;;
            * ) rm -f "$entry" ;;
          esac
        done
      fi
    ''
    + lib.optionalString cfg.symlink.enable (
      let
        targets = cfg.symlink.targets;
      in
      lib.concatStringsSep "\n" (
        map (target: ''
          mkdir -p "$(dirname '${target}')"
          ln -sfn '${resolvedDir}' '${target}'
        '') targets
      )
    );

  resolvePath =
    path: homeDir: if lib.hasPrefix "~" path then "${homeDir}${lib.removePrefix "~" path}" else path;
in

{
  inherit
    parseSkill
    getRegistryEntry
    fetchRepo
    readSkillName
    findSkillsInDir
    discoverSkills
    processEntry
    buildAllFileEntries
    detectConflicts
    mkActivationScript
    resolvePath
    ;
}
