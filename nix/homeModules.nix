{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.skills;
  mkSkills = import ./mkSkills.nix { inherit lib pkgs; };

  resolvePath =
    path:
    if lib.hasPrefix "~" path then "${config.home.homeDirectory}${lib.removePrefix "~" path}" else path;

  resolvedDir = resolvePath cfg.dir;

  skillSources = lib.listToAttrs (
    map (
      e:
      lib.nameValuePair e.name {
        source = e.storePath;
        recursive = true;
      }
    ) (mkSkills cfg.install resolvedDir)
  );

  agentSkillsDirs = [
    "~/.aider/skills"
    "~/.amazonq/skills"
    "~/.augment/skills"
    "~/.claude/skills"
    "~/.cline/skills"
    "~/.codeium/windsurf/skills"
    "~/.codex/skills"
    "~/.config/opencode/skills"
    "~/.continue/skills"
    "~/.copilot/skills"
    "~/.cursor/skills"
    "~/.gemini/skills"
    "~/.kilocode/skills"
    "~/.openclaw/skills"
    "~/.pi/agent/skills"
    "~/.roo/skills"
    "~/.sourcegraph/skills"
  ];

  symlinkTargets = lib.optionals cfg.enableAgentSymlinks agentSkillsDirs ++ cfg.customSymlinkTargets;

  agentLinks = lib.optionalAttrs (symlinkTargets != [ ]) (
    lib.genAttrs (map resolvePath symlinkTargets) (_: {
      source = config.lib.file.mkOutOfStoreSymlink resolvedDir;
    })
  );
in

{
  options.skills = {
    enable = lib.mkEnableOption "AI agent skills manager";

    install = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "vercel-labs/agent-skills"
        "mattpocock/skills@grill-me"
      ];
      description = ''
        Skills to install.
        Format: "owner/repo" or "owner/repo@skillName"
      '';
    };

    dir = lib.mkOption {
      type = lib.types.str;
      default = "~/.agents/skills";
      description = ''
        Install directory.
        ~ expands to home.
      '';
    };

    enableAgentSymlinks = lib.mkEnableOption ''
      symlinks for known AI agent skill directories:
      aider, amazonq, augment, claude, cline, codeium/windsurf, codex,
      opencode, continue, copilot, cursor, gemini, kilocode, openclaw,
      pi/agent, roo, sourcegraph
    '';

    customSymlinkTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "~/.local/share/my-agent/skills" ];
      description = ''
        Extra directories to symlink. Use with enableAgentSymlinks.
        ~ expands to home.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge [
      skillSources
      agentLinks
    ];
  };
}
