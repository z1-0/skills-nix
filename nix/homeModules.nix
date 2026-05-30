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

  agentLinks = lib.optionalAttrs cfg.symlink.enable (
    lib.genAttrs (map resolvePath cfg.symlink.targets) (_: {
      source = config.lib.file.mkOutOfStoreSymlink resolvedDir;
    })
  );
in

{
  options.skills = {
    enable = lib.mkEnableOption "Declarative AI agent skills manager";

    install = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "vercel-labs/agent-skills"
        "mattpocock/skills@grill-me"
      ];
      description = ''
        List of skills to install.
        Format: "owner/repo" or "owner/repo@skillName"
      '';
    };

    dir = lib.mkOption {
      type = lib.types.str;
      default = "~/.agents/skills";
      description = ''
        Installation directory for skills.
        Supports ~ for home directory (home-manager only).
        On NixOS/nix-darwin, use an absolute path.
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
        description = ''
          List of directories to symlink to the install directory.
          Supports ~ for home directory (home-manager only).
          On NixOS/nix-darwin, use absolute paths.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge [
      skillSources
      agentLinks
    ];
  };
}
