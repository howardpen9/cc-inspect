# cc-inspect

A Claude Code skill that instantly shows all your installed skills, plugins, MCP servers, commands, and hooks in a browser dashboard.

[English](#features) | [繁體中文](#功能特色)

![cc-inspect light mode](screenshot.png)

![cc-inspect dark mode](screenshot-dark.png)

## Features

- **Scope-aware**: shows User (`~/.claude/`), Project (`.claude/`), and Local (`settings.local.json`) layers
- **Clickable scope filter** — badge counts update dynamically
- **Collapsible sections** for Skills, Plugins, MCP Servers, Commands, Hooks, Memory
- **Memory hygiene audit** — flags stale, orphaned, and duplicated memory directories
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
| Memory | `~/.claude/CLAUDE.md`, `~/.claude/projects/<encoded>/memory/*.md`, `~/.claude/agent-memory/*` | User |

## Memory Hygiene

Claude Code writes auto-memory into per-project folders under `~/.claude/projects/<encoded>/memory/`. After a few months of everyday use, that tree easily grows to 20+ directories — including entries for projects you deleted, renamed, or only touched once. cc-inspect's Memory section is a cleanup recommender: it groups what's there by action needed and gives you copy-to-clipboard archive commands.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshot-memory-dark.png">
  <img src="screenshot-memory.png" alt="Memory Hygiene view — grouped cleanup recommendations">
</picture>

Instead of a file browser, you get grouped recommendations:

| Group | What it contains | Action |
|-------|------------------|--------|
| Sanity warnings | Anomalies like memory under the home directory | Awareness only |
| Orphans | Source project directory no longer exists, or no session `.jsonl` to verify it | Copy archive command |
| Stale | All MD files older than 30 days, project still alive | Copy archive command |
| Duplicates | MD5-matched content across different memory dirs | Per-cluster dedupe command (keeps newest) |
| Agent sessions | `.slock/agents/<uuid>` — transient per-agent memory | Copy bulk archive command |
| Live | Healthy dirs with recent activity (collapsed by default) | None |

Archive commands move directories into `~/.claude-archive/YYYYMMDD/` so cleanup is reversible — nothing is deleted.

Locations are decoded from the ground-truth `cwd` field in session `.jsonl` files rather than naive path-to-slash reversal, so folders with real dashes or unusual characters resolve correctly.

The view only reports locations, sizes, and timestamps. File contents are hashed for duplicate detection but never read into the dashboard.

---

## 繁體中文

### 功能特色

cc-inspect 是一個 Claude Code skill，執行 `/inspect` 後會立即在瀏覽器中打開一個 dashboard，展示你所有已安裝的模塊：

- **三層 Scope 感知**：區分 User（全域）、Project（專案）、Local（本機覆蓋）
- **可點擊的 Scope 篩選器**：切換後數字 badge 即時更新
- **可折疊的分類區塊**：Skills、Plugins、MCP Servers、Commands、Hooks、Memory
- **記憶體衛生審計**：標記過期、孤立、重複的記憶體目錄
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

### 記憶體衛生

Claude Code 會把自動記憶體寫進 `~/.claude/projects/<encoded>/memory/` 下的各專案資料夾。用上幾個月之後，這個目錄樹很容易累積 20+ 個資料夾，裡面混雜了已刪除、改名、或只用過一次的專案。cc-inspect 的 Memory 區塊是一個清理建議引擎：把條目依「該做什麼動作」分組，並附上可直接複製貼到 terminal 的封存指令。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshot-memory-dark.png">
  <img src="screenshot-memory.png" alt="記憶體衛生檢視 — 分組的清理建議">
</picture>

不是檔案瀏覽器，是分組的清理建議：

| 分組 | 內容 | 動作 |
|------|------|------|
| Sanity warnings | 異常狀態（例如家目錄下有 memory） | 提示性質 |
| Orphans | 原始專案目錄已不存在，或沒有 session `.jsonl` 可驗證 | 複製封存指令 |
| Stale | 所有 MD 檔都超過 30 天未更新，但專案還活著 | 複製封存指令 |
| Duplicates | 跨目錄的 MD5 內容重複 | 每個 cluster 獨立的去重指令（保留最新） |
| Agent sessions | `.slock/agents/<uuid>` — 每個 agent session 的暫時記憶 | 複製批量封存指令 |
| Live | 健康、近期有活動的目錄（預設收起） | 無 |

封存指令會把目錄移到 `~/.claude-archive/YYYYMMDD/`，是可逆操作，不會直接刪除。

Location 是從 session `.jsonl` 檔的 `cwd` 欄位反推得來（而非單純把編碼路徑的破折號換成斜線），含有真正破折號或特殊字元的路徑也能正確還原。

此檢視只回報位置、大小、時間戳記；檔案內容只會被拿去算 MD5 做重複偵測，絕不讀進 dashboard。

---

## License

MIT
