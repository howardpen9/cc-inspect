# cc-inspect

A Claude Code skill that instantly shows all your installed skills, plugins, MCP servers, commands, and hooks in a browser dashboard.

![cc-inspect light mode](screenshot.png)

![cc-inspect dark mode](screenshot-dark.png)

## Features

- Scope-aware: shows User (`~/.claude/`), Project (`.claude/`), and Local (`settings.local.json`) layers
- Clickable scope filter — badge counts update dynamically
- Collapsible sections for Skills, Plugins, MCP Servers, Commands, Hooks
- Auto-detects project scope from current working directory
- Light/dark mode follows system preference
- Zero dependencies — pure bash + python3, generates a self-contained HTML file

## Install

Copy the skill into your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills/cc-inspector
cp inspect.sh SKILL.md ~/.claude/skills/cc-inspector/
chmod +x ~/.claude/skills/cc-inspector/inspect.sh
```

## Usage

In any Claude Code conversation:

```
/inspect
```

A browser tab opens with your full Claude Code ecosystem dashboard.

## How it works

1. `inspect.sh` scans `~/.claude/` and the current project's `.claude/` directory
2. Collects skills, plugins, MCP servers, commands, and hooks from all scopes
3. Generates a self-contained HTML file at `/tmp/cc-inspector.html`
4. Opens it in the default browser via `open`

## License

MIT
