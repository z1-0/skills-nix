{ config, lib, pkgs, ... }:

let
  cfg = config.skills;

  registryJson = builtins.fromJSON (builtins.readFile ./registry.json);

  # Resolve ~ to home directory
  resolvePath = path:
    if lib.hasPrefix "~" path then
      "${config.home.homeDirectory}${lib.removePrefix "~" path}"
    else path;

  # Parse "owner/repo" or "owner/repo/path" into structured form
  parseSkill = skill:
    let
      parts = lib.splitString "/" skill;
      len = builtins.length parts;
      owner = lib.toLower (builtins.elemAt parts 0);
      repo = lib.toLower (builtins.elemAt parts 1);
      pathParts = lib.drop 2 parts;
      path = if pathParts != [] then lib.concatStringsSep "/" pathParts else null;
      name = if path != null then lib.last (lib.splitString "/" path) else repo;
      registryKey = "${owner}/${repo}";
    in
    if len < 2 then
      throw "Invalid skill format '${skill}': expected 'owner/repo' or 'owner/repo/path'"
    else {
      inherit owner repo name path registryKey;
    };

  # Look up repo in registry (case-insensitive)
  getRegistryEntry = parsed:
    let
      entry = registryJson.repos.${parsed.registryKey} or null;
    in
    if entry == null then
      throw "Skill repo '${parsed.registryKey}' not found in registry. See ${toString ./registry.json} for available repos."
    else entry;

  # Fetch repo from GitHub
  fetchRepo = parsed: entry:
    pkgs.fetchFromGitHub {
      owner = parsed.owner;
      repo = parsed.repo;
      rev = entry.rev;
      hash = entry.hash;
    };

  # Read name from SKILL.md frontmatter, fall back to defaultName
  readSkillName = defaultName: skillDir:
    let
      mdPath = "${skillDir}/SKILL.md";
    in
    if !builtins.pathExists mdPath then defaultName else
    let
      parts = lib.splitString "---" (builtins.readFile mdPath);
    in
    if builtins.length parts < 3 then defaultName else
    let
      frontmatter = builtins.elemAt parts 1;
      lines = lib.splitString "\n" frontmatter;
      nameLine = lib.findFirst (line:
        builtins.substring 0 5 (builtins.replaceStrings [" " "\t"] ["" ""] line) == "name:"
      ) null lines;
    in
    if nameLine != null then
      let
        raw = builtins.substring 5 (builtins.stringLength nameLine - 5) nameLine;
        withoutLeading = if builtins.substring 0 1 raw == " " then
          builtins.substring 1 (builtins.stringLength raw - 1) raw
        else raw;
        name = if builtins.stringLength withoutLeading >= 2
            && builtins.substring 0 1 withoutLeading == "\""
            && builtins.substring (builtins.stringLength withoutLeading - 1) 1 withoutLeading == "\""
          then builtins.substring 1 (builtins.stringLength withoutLeading - 2) withoutLeading
          else if builtins.stringLength withoutLeading >= 2
            && builtins.substring 0 1 withoutLeading == "'"
            && builtins.substring (builtins.stringLength withoutLeading - 1) 1 withoutLeading == "'"
          then builtins.substring 1 (builtins.stringLength withoutLeading - 2) withoutLeading
          else withoutLeading;
      in
      if name != "" then name else defaultName
    else defaultName;

  # Install a single skill directory
  installSkill = name: source:
    lib.nameValuePair "${resolvedDir}/${name}" {
      source = source;
      recursive = true;
    };

  # Find SKILL.md files in a directory (recursive, depth-limited)
  # depth: -1 = unlimited, 0 = stop, >0 = recurse with decrement
  findSkillsInDir = dir: depth:
    let
      shouldRecurse = depth == -1 || depth > 0;
      nextDepth = if depth == -1 then -1 else depth - 1;
      entries = builtins.readDir dir;
      dirs = lib.filterAttrs (n: v: v == "directory") entries;
      subdirs = lib.mapAttrsToList (name: path: {
        inherit name;
        path = name;
      }) dirs;
      checkDir = entry:
        let
          subEntries = builtins.readDir "${dir}/${entry.name}";
        in
        if builtins.hasAttr "SKILL.md" subEntries then
          [ entry ]
        else if shouldRecurse && nextDepth != 0
          && builtins.length (builtins.attrNames (lib.filterAttrs (n: v: v == "directory") subEntries)) > 0
        then
          map (s: s // { path = "${entry.path}/${s.path}"; }) (findSkillsInDir "${dir}/${entry.name}" nextDepth)
        else
          [];
    in
    lib.concatMap checkDir subdirs;

  # Handle naming conflicts during skill discovery
  resolveConflict = skills: skill:
    let
      existingNames = map (s: s.name) skills;
      uniqueName = if builtins.elem skill.name existingNames then
        # Append parent directory name to resolve conflict
        let parts = lib.splitString "/" skill.path;
        in if builtins.length parts > 1 then
          lib.last (lib.init parts) + "-" + skill.name
        else
          skill.name + "-1"
      else
        skill.name;
    in
    { name = uniqueName; path = skill.path; };

  # Discover all skills from a repo (no path specified)
  discoverSkills = parsed: repoPath:
    let
      # Scan repo/*/SKILL.md — flat subdirectories at root
      flatSkills = findSkillsInDir repoPath 1;
      hasRootSkill = builtins.pathExists "${repoPath}/SKILL.md";
      # Scan repo/SKILL.md — root itself is the skill
      rootSkill = if hasRootSkill then [{ name = parsed.name; path = "."; }] else [];
      skillsDir = "${repoPath}/skills";
      skillsDirExists = builtins.pathExists skillsDir;
      searchDepth = if cfg.depth <= 0 then -1 else cfg.depth;
      # Scan repo/skills/*/.../SKILL.md — nested directory
      nestedSkills = if skillsDirExists then
        map (s: s // { path = "skills/${s.path}"; }) (findSkillsInDir skillsDir searchDepth)
      else [];
      allSkills = flatSkills ++ nestedSkills ++ rootSkill;
    in
    if allSkills == [] then
      throw "No skills found in '${parsed.registryKey}' (${repoPath}) - no SKILL.md files discovered"
    else
      # Resolve names from SKILL.md frontmatter, then fold to resolve conflicts
      let
        withNames = map (s:
          s // { name = readSkillName s.name "${repoPath}/${s.path}"; }
        ) allSkills;
        resolved = lib.foldl' (acc: skill: acc ++ [ (resolveConflict acc skill) ]) [] withNames;
      in
      resolved;

  # Resolve the install directory
  resolvedDir = resolvePath cfg.dir;


  # Process a single install entry
  processEntry = skill:
    let
      parsed = parseSkill skill;
      entry = getRegistryEntry parsed;
      repoPath = fetchRepo parsed entry;
    in
    if parsed.path != null then
      # Specific path: find SKILL.md in repo/<path> or repo/skills/<path>
      let
        candidates = [
          "${repoPath}/skills/${parsed.path}"
          "${repoPath}/${parsed.path}"
        ];
        validCandidates = builtins.filter (p: builtins.pathExists "${p}/SKILL.md") candidates;
      in
      if validCandidates == [] then
        throw "Skill '${parsed.path}' not found in '${skill}'"
      else
        let
          skillSource = builtins.head validCandidates;
          skillName = readSkillName parsed.name skillSource;
        in
        [ (installSkill skillName skillSource) ]
    else
      # Discovery: find all skills in the repo
      let
        discovered = discoverSkills parsed repoPath;
        skillEntries = map (s: installSkill s.name "${repoPath}/${s.path}") discovered;
      in
      skillEntries;

  # Process all install entries
  allFileEntries = lib.listToAttrs (lib.concatMap processEntry cfg.install);

  # Create symlinks to agent directories
  symlinkEntries =
    if !cfg.symlink.enable then {}
    else
      let
        targets = map resolvePath cfg.symlink.targets;
      in
      lib.genAttrs targets (target: {
        source = config.lib.file.mkOutOfStoreSymlink resolvedDir;
      });

in
{
  options.skills = {
    enable = lib.mkEnableOption "Declarative AI agent skills manager";

    install = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [
        "vercel-labs/agent-skills"
        "mattpocock/skills/grill-me"
      ];
      description = ''
        List of skills to install.
        Format: "owner/repo" or "owner/repo/path"
      '';
    };

    dir = lib.mkOption {
      type = lib.types.str;
      default = "~/.agents/skills";
      description = ''
        Installation directory for skills.
        Supports ~ for home directory.
      '';
    };

    depth = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = ''
        Search depth for skill discovery in skills/ directory.
        Root directory is always scanned 1 level deep.
        Use <= 0 for full recursion.
      '';
    };

    symlink = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to create symlinks from target directories to the install directory.";
      };

      targets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "~/.continue/skills"
          "~/.cursor/skills"
          "~/.codeium/windsurf/skills"
        ];
        description = ''
          List of directories to symlink to the install directory.
          Supports ~ for home directory.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge [
      allFileEntries
      symlinkEntries
    ];
  };
}
