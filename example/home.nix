# Add skills-nix to your home-manager configuration:
#
#   inputs = {
#     skills-nix.url = "github:z1-0/skills-nix";
#   };
#
#   imports = [ inputs.skills-nix.homeModules.default ];
{ config, ... }: {
  skills = {
    enable = true;

    install = [
      # "owner/repo" or "owner/repo@skillName"
      "vercel-labs/agent-skills"      # all skills from a repo
      "mattpocock/skills@grill-me"    # a specific skill by name
    ];

    # Install directory. ~ expands to home.
    dir = "~/.agents/skills";

    symlink = {
      enable = true;
      targets = [
        "~/.claude/skills"
        "~/.cursor/skills"
        "~/.codeium/windsurf/skills"
      ];
    };
  };
}
