{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.skills;

  registryJson = builtins.fromJSON (builtins.readFile ./registry.json);

  parseSkill =
    skill:
    let
      parts = lib.splitString "@" skill;
      owner = lib.toLower (builtins.elemAt parts 0);
      repo = lib.toLower (builtins.elemAt subparts 0);
      repoAndSubdir = builtins.elemAt parts 1;
      subparts = lib.splitString "/" repoAndSubdir;
      subdirParts = lib.filter (p: p != "") (lib.drop 1 subparts);
      subdir = if subdirParts != [ ] then lib.concatStringsSep "/" subdirParts else null;
      name = if subdir != null then lib.last (lib.splitString "/" subdir) else repo;
    in
    {
      inherit
        owner
        repo
        name
        subdir
        ;
    };

  getSkillHash =
    skill:
    let
      parsed = parseSkill skill;
      repoKey = "${parsed.owner}/${parsed.repo}";
      hash = registryJson.repos.${repoKey} or null;
    in
    if hash == null then throw "Skill repo '${repoKey}' not found in registry" else hash;

  getSkillSource =
    skill:
    let
      parsed = parseSkill skill;
      hash = getSkillHash skill;
      repo = pkgs.fetchFromGitHub {
        inherit (parsed) owner repo;
        rev = "main";
        sha256 = hash;
      };
    in
    if parsed.subdir != null then "${repo}/${parsed.subdir}" else repo;

  skillsAbsPath =
    if lib.hasPrefix "/" cfg.skillsDir then
      cfg.skillsDir
    else
      "${config.home.homeDirectory}/${cfg.skillsDir}";

  agentDirectories = {
    "claude-code" = ".claude/skills";
    "codex" = ".codex/skills";
    "copilot" = ".copilot/skills";
    "cursor" = ".cursor/skills";
    "gemini" = ".gemini/skills";
    "opencode" = ".config/opencode/skills";
    "roo" = ".roo/skills";
    "windsurf" = ".codeium/windsurf/skills";
  };

  enabledAgentDirs = lib.filterAttrs (_: path: path != cfg.skillsDir) (
    if cfg.linkToAgents == [ "*" ] then
      agentDirectories
    else
      lib.filterAttrs (name: _: builtins.elem name cfg.linkToAgents) agentDirectories
  );

  buildSkillSource =
    skill:
    let
      parsed = parseSkill skill;
      source = getSkillSource skill;
    in
    lib.nameValuePair "${cfg.skillsDir}/${parsed.name}" {
      source = source;
      recursive = true;
    };

  allFileEntries = lib.listToAttrs (map buildSkillSource cfg.fetch);

  agentSymlinks = lib.mapAttrs' (
    _: path:
    lib.nameValuePair path {
      source = config.lib.file.mkOutOfStoreSymlink skillsAbsPath;
    }
  ) enabledAgentDirs;

in
{
  options.skills = {
    enable = lib.mkEnableOption "NixOS Agents Skills Manager";

    fetch = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "vercel-labs@skills/skills/find-skills"
        "mattpocock@skills/skills/grill-me"
      ];
      description = ''
        List of skills to install.
        Format: "owner@repo/subdir"
      '';
    };

    skillsDir = lib.mkOption {
      type = lib.types.str;
      default = ".agents/skills";
      description = "Installation directory for skills (relative to home or absolute)";
    };

    linkToAgents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "*" ];
      example = [
        "claude-code"
        "cursor"
        "codex"
      ];
      description = ''
        List of agents to symlink skills to.
        Use ["*"] to link to all supported agents.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge [
      allFileEntries
      agentSymlinks
    ];
  };
}
