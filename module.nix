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
  getRegistryEntry = skill:
    let
      parsed = parseSkill skill;
      key = parsed.registryKey;
      entry = registryJson.repos.${key} or null;
    in
    if entry == null then
      throw "Skill repo '${key}' not found in registry. See ${toString ./registry.json} for available repos."
    else entry;

  # Fetch repo from GitHub
  fetchRepo = skill:
    let
      parsed = parseSkill skill;
      entry = getRegistryEntry skill;
    in
    pkgs.fetchFromGitHub {
      owner = parsed.owner;
      repo = parsed.repo;
      rev = entry.rev;
      hash = entry.hash;
    };

  # Install a single skill directory
  installSkill = name: source:
    lib.nameValuePair "${resolvedDir}/${name}" {
      source = source;
      recursive = true;
    };

  # Find SKILL.md files in a directory (1 level deep)
  findSkillsAtRoot = dir:
    let
      entries = builtins.readDir dir;
      dirs = lib.filterAttrs (n: v: v == "directory") entries;
      hasSkillMd = name:
        let
          subEntries = builtins.readDir "${dir}/${name}";
        in
        builtins.hasAttr "SKILL.md" subEntries;
      skillDirs = lib.filterAttrs (n: _: hasSkillMd n) dirs;
    in
    lib.mapAttrsToList (name: _: { inherit name; path = name; }) skillDirs;

  # Find SKILL.md files in skills/ directory (recursive, depth-limited)
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
      # Check each subdir for SKILL.md
      checkDir = entry:
        let
          subEntries = builtins.readDir "${dir}/${entry.name}";
        in
        if builtins.hasAttr "SKILL.md" subEntries then
          [ entry ]
        else if shouldRecurse then
          let
            deeperEntries = builtins.readDir "${dir}/${entry.name}";
            deeperDirs = lib.filterAttrs (n: v: v == "directory") deeperEntries;
            deeperResults = lib.mapAttrsToList (n: _: {
              name = n;
              path = "${entry.path}/${n}";
            }) deeperDirs;
          in
          if builtins.length (builtins.attrNames deeperDirs) > 0 && nextDepth != 0 then
            findSkillsInDir "${dir}/${entry.name}" nextDepth
          else
            []
        else
          [];
    in
    lib.concatMap checkDir subdirs;

  # Discover all skills from a repo (no path specified)
  discoverSkills = skill: repoPath:
    let
      # Scan repo/*/SKILL.md — flat subdirectories at root
      flatSkills = findSkillsAtRoot repoPath;
      hasRootSkill = builtins.pathExists "${repoPath}/SKILL.md";
      rootSkillName = (parseSkill skill).name;
      # Scan repo/SKILL.md — root itself is the skill
      rootSkill = if hasRootSkill then [{ name = rootSkillName; path = "."; }] else [];
      skillsDir = "${repoPath}/skills";
      skillsDirExists = builtins.pathExists skillsDir;
      searchDepth = if cfg.depth <= 0 then -1 else cfg.depth;
      # Scan repo/skills/*/.../SKILL.md — nested directory
      nestedSkills = if skillsDirExists then
        map (s: s // { path = "skills/${s.path}"; }) (findSkillsInDir skillsDir searchDepth)
      else [];
      allSkills = flatSkills ++ nestedSkills ++ rootSkill;
      # Handle naming conflicts
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
    in
    if allSkills == [] then
      throw "No skills found in '${skill}' (${repoPath}) - no SKILL.md files discovered"
    else
      # Fold to resolve conflicts
      let
        resolved = lib.foldl' (acc: skill: acc ++ [ (resolveConflict acc skill) ]) [] allSkills;
      in
      resolved;

  # Resolve the install directory
  resolvedDir = resolvePath cfg.dir;

  # Check if a path contains a SKILL.md
  hasSkillMd = p: builtins.pathExists "${p}/SKILL.md";

  # Process a single install entry
  processEntry = skill:
    let
      parsed = parseSkill skill;
      repoPath = fetchRepo skill;
    in
    if parsed.path != null then
      # Specific path: find SKILL.md in repo/<path> or repo/skills/<path>
      let
        candidates = [
          "${repoPath}/skills/${parsed.path}"
          "${repoPath}/${parsed.path}"
        ];
        validCandidates = builtins.filter hasSkillMd candidates;
      in
      if validCandidates == [] then
        throw "Skill '${parsed.path}' not found in '${skill}'"
      else
        [ (installSkill parsed.name (builtins.head validCandidates)) ]
    else
      # Discovery: find all skills in the repo
      let
        discovered = discoverSkills skill repoPath;
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
