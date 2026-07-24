# Example configuration for skills-nix
#
# Add this flake to your home-manager configuration:
#
#   inputs = {
#     skills-nix.url = "github:z1-0/skills-nix";
#   };
#
# Then import the module:
#
#   imports = [ inputs.skills-nix.homeModules.default ];
#
# And configure skills:
{ config, ... }: {
  skills = {
    # Enable the skills manager
    enable = true;

    # List of skills to install
    # Format: "owner/repo" or "owner/repo/path"
    install = [
      # Install all skills from a repo
      # The module scans for SKILL.md files automatically
      "vercel-labs/agent-skills"

      # Install a specific skill from a multi-skill repo
      "mattpocock/skills/grill-me"
    ];

    # Installation directory (supports ~ for home directory)
    # Default: "~/.agents/skills"
    dir = "~/.agents/skills";

    # Search depth for skill discovery in skills/ directory
    # Root directory is always scanned 1 level deep
    # Use <= 0 for full recursion
    # Default: 2
    depth = 2;

    # Symlink configuration
    symlink = {
      # Whether to create symlinks from agent directories
      # to the install directory
      enable = true;

      # Directories to symlink (supports ~ for home directory)
      # These are the directories where agents look for skills
      targets = [
        "~/.claude/skills"
        "~/.cursor/skills"
        "~/.codeium/windsurf/skills"
      ];
    };
  };
}
