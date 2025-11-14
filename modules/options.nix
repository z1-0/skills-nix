{ lib }:

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
}