<div align="center">

# skills-nix

[![CI](https://img.shields.io/github/actions/workflow/status/z1-0/skills-nix/update-registry.yml?style=flat-square)](https://github.com/z1-0/skills-nix/actions/workflows/update-registry.yml)
[![Repos](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Fz1-0%2Fskills-nix%2Fmain%2Fregistry.json&query=%24.count&label=repos&style=flat-square&color=00add8)](registry.json)
[![License](https://img.shields.io/badge/License-BSD_3--Clause-blue?style=flat-square)](LICENSE)

</div>

skills-nix is a Home Manager module for AI agent skills. It uses the same discovery and installation logic as skills.sh, and supports the same repos.

## Quick start

### 1. Add the flake input

```nix
inputs.skills-nix.url = "github:z1-0/skills-nix";
```

### 2. Import module and configure

```nix
{
  imports = [
    skills-nix.homeModules.default
  ];

  skills = {
    enable = true;
    enableAgentSymlinks = true;
    install = [
      "vercel-labs/agent-skills"
      "mattpocock/skills@grill-me"
    ];
  };
}
```

## Configuration

| Option                 | Type            | Default              | Description                                                                   |
| ---------------------- | --------------- | -------------------- | ----------------------------------------------------------------------------- |
| `enable`               | bool            | `false`              | Enable the skills module.                                                     |
| `install`              | list of strings | `[]`                 | Skills to install. Format: `"owner/repo"` or `"owner/repo@skillName"`.        |
| `dir`                  | string          | `"~/.agents/skills"` | Installation directory. `~` expands to home.                                  |
| `enableAgentSymlinks`  | bool            | `false`              | Create symlinks in all 17 supported agent skill directories (see list below). |
| `customSymlinkTargets` | list of strings | `[]`                 | Extra directories to symlink. Use with `enableAgentSymlinks`.                 |

### Install format

Specify skills as `"owner/repo"` or `"owner/repo@skillName"`:

```nix
skills.install = [
  "vercel-labs/agent-skills"          # install all skills from the repo
  "mattpocock/skills@grill-me"        # install only the "grill-me" skill
];
```

Add the `@skillName` suffix to install one skill from a multi-skill repo. Without it, all skills from the repo install.

### Supported agents

Set `enableAgentSymlinks` to `true` to symlink skills into all 17 supported agent directories:

| Agent              | Skill directory              |
| ------------------ | ---------------------------- |
| Aider              | `~/.aider/skills`            |
| Amazon Q           | `~/.amazonq/skills`          |
| Augment            | `~/.augment/skills`          |
| Claude             | `~/.claude/skills`           |
| Cline              | `~/.cline/skills`            |
| Codeium / Windsurf | `~/.codeium/windsurf/skills` |
| Codex              | `~/.codex/skills`            |
| OpenCode           | `~/.config/opencode/skills`  |
| Continue           | `~/.continue/skills`         |
| Copilot            | `~/.copilot/skills`          |
| Cursor             | `~/.cursor/skills`           |
| Gemini             | `~/.gemini/skills`           |
| KiloCode           | `~/.kilicode/skills`         |
| OpenClaw           | `~/.openclaw/skills`         |
| Pi / Agent         | `~/.pi/agent/skills`         |
| Roo                | `~/.roo/skills`              |
| Sourcegraph        | `~/.sourcegraph/skills`      |

### Custom symlink targets

```nix
skills = {
  enable = true;
  enableAgentSymlinks = true;
  customSymlinkTargets = [
    "~/.local/share/my-agent/skills"
  ];
};
```

## How it works

A weekly workflow scans skills.sh for GitHub-hosted skills, resolves the latest commit and Nix hash, and publishes to `registry.json`. Add repos to `skills.install` to pin versions and install skills.

```
                    ┌─────────────────────────────────┐
                    │  skills.install = [             │
                    │    "vercel-labs/agent-skills"   │
                    │    "mattpocock/skills@grill-me" │
                    │  ];                             │
                    └──────────┬──────────────────────┘
                               │
                    ┌──────────▼──────────────────────┐
                    │        Nix build                │
                    │                                 │
                    │  fetchFromGitHub → Nix store    │
                    │  discover SKILL.md files        │
                    │  resolve name conflicts         │
                    └──────────┬──────────────────────┘
                               │
                    ┌──────────▼──────────────────────┐
                    │      Installation               │
                    │                                 │
                    │  ~/.agents/skills/<name>        │
                    │  ↳ ~/.claude/skills/<name>      │
                    │  ↳ ~/.cursor/skills/<name>      │
                    │  ↳ ~/.config/opencode/skills/   │
                    │  ↳ ... (17 agents supported)    │
                    └─────────────────────────────────┘
```

### Skills discovery

`skills-nix` looks for skills in these locations within each fetched repo:

1. A `SKILL.md` at the repo root counts as the skill.
2. Any subdirectory containing a `SKILL.md`.
3. The `skills/` directory scans all subdirectories for `SKILL.md` files.

The `SKILL.md` frontmatter `name` field provides the skill name. The directory name is a fallback when the field is absent.

### Conflict resolution

If two repos provide a skill with the same name, the build fails. For example:

```
Conflicting skill names:

  "grill-me" provided by:
    - mattpocock/skills
    - another-org/skills
```

A bare `"owner/repo"` installs all skills from that repo. Resolve conflicts with either:

- **Remove** one conflicting repo from `install`.
- **Use `@skillName` on both sides** to install only specific skills, avoiding the overlap. You must list every skill you want from each repo.
