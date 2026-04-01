# cc-inspect

A Claude Code skill that instantly shows all your installed skills, plugins, MCP servers, commands, and hooks in a browser dashboard.

[English](#features) | [繁體中文](#功能特色)

![cc-inspect light mode](screenshot.png)

![cc-inspect dark mode](screenshot-dark.png)

## Features

- **Scope-aware**: shows User (`~/.claude/`), Project (`.claude/`), and Local (`settings.local.json`) layers
- **Clickable scope filter** — badge counts update dynamically
- **Collapsible sections** for Skills, Plugins, MCP Servers, Commands, Hooks
- **Auto-detects** project scope from current working directory
- **Light/dark mode** follows system preference
- **Zero dependencies** — pure bash + python3, generates a self-contained HTML file

## Install

```bash
git clone https://github.com/howardpen9/cc-inspect.git
cd cc-inspect
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

## Requirements

- macOS (uses `open` command; Linux users can change to `xdg-open`)
- Python 3 (for JSON parsing and YAML frontmatter extraction)
- Claude Code CLI

## What it scans

| Source | Path | Scope |
|--------|------|-------|
| Skills | `~/.claude/skills/` | User |
| Skills | `<project>/.claude/skills/` | Project |
| Plugins | `~/.claude/plugins/marketplaces/` | User |
| MCP Servers | `settings.json` → `mcpServers` | User / Project / Local |
| Commands | `~/.claude/commands/` | User |
| Commands | `<project>/.claude/commands/` | Project |
| Hooks | `settings.json` → `hooks` | User / Project / Local |

---

## 繁體中文

### 功能特色

cc-inspect 是一個 Claude Code skill，執行 `/inspect` 後會立即在瀏覽器中打開一個 dashboard，展示你所有已安裝的模塊：

- **三層 Scope 感知**：區分 User（全域）、Project（專案）、Local（本機覆蓋）
- **可點擊的 Scope 篩選器**：切換後數字 badge 即時更新
- **可折疊的分類區塊**：Skills、Plugins、MCP Servers、Commands、Hooks
- **自動偵測**當前工作目錄的專案 scope
- **亮色 / 暗色模式**跟隨系統設定
- **零依賴**：純 bash + python3，產生一個 self-contained HTML 檔案

### 安裝

```bash
git clone https://github.com/howardpen9/cc-inspect.git
cd cc-inspect
mkdir -p ~/.claude/skills/cc-inspector
cp inspect.sh SKILL.md ~/.claude/skills/cc-inspector/
chmod +x ~/.claude/skills/cc-inspector/inspect.sh
```

### 使用方式

在任何 Claude Code 對話中輸入：

```
/inspect
```

瀏覽器會自動打開，展示你的 Claude Code 生態系統全貌。

### 運作原理

1. `inspect.sh` 掃描 `~/.claude/` 和當前專案的 `.claude/` 目錄
2. 收集所有 skills、plugins、MCP servers、commands、hooks
3. 產生 self-contained HTML 檔案到 `/tmp/cc-inspector.html`
4. 透過 `open` 指令在瀏覽器中打開

---

## License

MIT
