#!/usr/bin/env bash
# cc-inspector: scan Claude Code ecosystem across all scopes, generate HTML dashboard
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
OUT="/tmp/cc-inspector.html"
NOW=$(date "+%Y-%m-%d %H:%M")

# --- Detect project scope ---
PROJECT_DIR=""
PROJECT_NAME=""
check="$(pwd)"
while [[ "$check" != "/" ]]; do
  if [[ -d "$check/.claude" && "$check" != "$HOME" ]]; then
    PROJECT_DIR="$check/.claude"
    PROJECT_NAME=$(basename "$check")
    break
  fi
  check=$(dirname "$check")
done

# --- Scope-aware collectors ---

collect_skills() {
  local scope="$1" dir="$2"
  [[ -d "$dir" ]] || return
  for skill in "$dir"/*/; do
    [[ -d "$skill" ]] || continue
    local name=$(basename "$skill")
    [[ "$name" == "cc-inspector" ]] && continue
    local desc=""
    local skillfile=""
    for f in "$skill/SKILL.md" "$skill"/*.md; do
      [[ -f "$f" ]] && skillfile="$f" && break
    done
    if [[ -n "$skillfile" ]]; then
      # Parse YAML frontmatter: handle both single-line and multiline description
      desc=$(python3 -c "
import re, sys
text = open('$skillfile').read()
# Try single-line: description: some text
m = re.search(r'^description:\s+([^|\n].+)$', text, re.MULTILINE)
if m:
    print(m.group(1).strip())
    sys.exit()
# Try multiline: description: |
m = re.search(r'^description:\s*\|\s*\n((?:[ \t]+.+\n?)+)', text, re.MULTILINE)
if m:
    lines = m.group(1).strip().split('\n')
    # Take first sentence/line, truncate to ~120 chars
    first = lines[0].strip()
    if len(first) > 120:
        first = first[:117] + '...'
    print(first)
" 2>/dev/null)
    fi
    # If no description, show source path as hint
    if [[ -z "$desc" ]]; then
      local source_hint=$(echo "$dir/$name" | sed "s|$HOME|~|")
      desc="<span class=\"source-hint\">$source_hint</span>"
    fi
    echo "<tr data-scope=\"${scope}\"><td><span class=\"scope-tag scope-${scope}\">${scope}</span></td><td>/$name</td><td>${desc}</td></tr>"
  done
}

collect_commands() {
  local scope="$1" dir="$2"
  [[ -d "$dir" ]] || return
  for cmd in "$dir"/*.md; do
    [[ -f "$cmd" ]] || continue
    local name=$(basename "$cmd" .md)
    local source_hint=$(echo "$cmd" | sed "s|$HOME|~|")
    echo "<tr data-scope=\"${scope}\"><td><span class=\"scope-tag scope-${scope}\">${scope}</span></td><td>/$name</td><td><span class=\"source-hint\">$source_hint</span></td></tr>"
  done
}

collect_mcp_from() {
  local scope="$1" settings="$2"
  [[ -f "$settings" ]] || return
  local source_hint=$(echo "$settings" | sed "s|$HOME|~|")
  python3 -c "
import json, html
with open('$settings') as f:
    d = json.load(f)
for name, cfg in d.get('mcpServers', {}).items():
    cmd = cfg.get('command', '')
    args = ' '.join(str(a) for a in cfg.get('args', [])[:2])
    detail = html.escape(f'{cmd} {args}')
    src = '$source_hint'
    print(f'<tr data-scope=\"$scope\"><td><span class=\"scope-tag scope-$scope\">$scope</span></td><td>{html.escape(name)}</td><td>{detail} <span class=\"source-hint\">({src})</span></td></tr>')
" 2>/dev/null || true
}

collect_hooks_from() {
  local scope="$1" settings="$2"
  [[ -f "$settings" ]] || return
  local source_hint=$(echo "$settings" | sed "s|$HOME|~|")
  python3 -c "
import json, html
with open('$settings') as f:
    d = json.load(f)
for event, matchers in d.get('hooks', {}).items():
    for m in matchers:
        matcher = m.get('matcher', '*')
        for h in m.get('hooks', []):
            cmd = h.get('command', '')
            cmd = cmd.replace('$HOME/', '~/').replace('\${HOME}/', '~/')
            src = '$source_hint'
            print(f'<tr data-scope=\"$scope\"><td><span class=\"scope-tag scope-$scope\">$scope</span></td><td>{html.escape(event)}</td><td>{html.escape(matcher or \"*\")}</td><td>{html.escape(cmd)} <span class=\"source-hint\">({src})</span></td></tr>')
" 2>/dev/null || true
}

collect_plugins() {
  local dir="$CLAUDE_DIR/plugins/marketplaces"
  [[ -d "$dir" ]] || return
  for marketplace in "$dir"/*/; do
    [[ -d "$marketplace" ]] || continue
    local mp_name=$(basename "$marketplace")
    local plugins_dir="$marketplace/plugins"
    [[ -d "$plugins_dir" ]] || continue
    for plugin in "$plugins_dir"/*/; do
      [[ -d "$plugin" ]] || continue
      local p_name=$(basename "$plugin")
      echo "<tr data-scope=\"user\"><td><span class=\"scope-tag scope-user\">user</span></td><td>$mp_name</td><td>$p_name</td></tr>"
    done
  done
}

# --- Counts ---
count_skills() {
  local c=0
  if [[ -d "$CLAUDE_DIR/skills" ]]; then
    c=$(ls -d "$CLAUDE_DIR/skills"/*/ 2>/dev/null | grep -cv cc-inspector || echo 0)
  fi
  if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR/skills" ]]; then
    local pc=$(ls -d "$PROJECT_DIR/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
    c=$((c + pc))
  fi
  echo "$c"
}

count_commands() {
  local c=0
  [[ -d "$CLAUDE_DIR/commands" ]] && c=$(ls "$CLAUDE_DIR/commands"/*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR/commands" ]]; then
    local pc=$(ls "$PROJECT_DIR/commands"/*.md 2>/dev/null | wc -l | tr -d ' ')
    c=$((c + pc))
  fi
  echo "$c"
}

count_json_key() {
  local key="$1" total=0
  for f in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json" \
           ${PROJECT_DIR:+"$PROJECT_DIR/settings.json"} ${PROJECT_DIR:+"$PROJECT_DIR/settings.local.json"}; do
    [[ -f "$f" ]] || continue
    local n=$(python3 -c "import json; print(len(json.load(open('$f')).get('$key',{})))" 2>/dev/null || echo 0)
    total=$((total + n))
  done
  echo "$total"
}

count_hooks_total() {
  local total=0
  for f in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json" \
           ${PROJECT_DIR:+"$PROJECT_DIR/settings.json"} ${PROJECT_DIR:+"$PROJECT_DIR/settings.local.json"}; do
    [[ -f "$f" ]] || continue
    local n=$(python3 -c "
import json
d=json.load(open('$f'))
print(sum(len(h.get('hooks',[])) for ms in d.get('hooks',{}).values() for h in ms))
" 2>/dev/null || echo 0)
    total=$((total + n))
  done
  echo "$total"
}

skill_count=$(count_skills)
plugin_count=$(find "$CLAUDE_DIR/plugins/marketplaces" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | wc -l | tr -d ' ')
command_count=$(count_commands)
mcp_count=$(count_json_key mcpServers)
hook_count=$(count_hooks_total)

# --- HTML ---
cat > "$OUT" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Code Inspector</title>
<style>
  :root {
    --bg: #faf9f7; --card: #fff; --border: #e8e4de;
    --text: #1a1a1a; --text2: #6b6560; --accent: #c96442;
    --accent-bg: #fef4f0; --badge: #f0ebe5;
    --scope-user: #7c6f64; --scope-user-bg: #f2ece4;
    --scope-project: #2877a8; --scope-project-bg: #e0f0fa;
    --scope-local: #6a8a20; --scope-local-bg: #eef5d8;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #1a1816; --card: #242220; --border: #3a3632;
      --text: #e8e4de; --text2: #9b9590; --accent: #e07850;
      --accent-bg: #2a2018; --badge: #2e2a26;
      --scope-user: #d5c4a1; --scope-user-bg: #3c3428;
      --scope-project: #83a598; --scope-project-bg: #1e3a30;
      --scope-local: #b8bb26; --scope-local-bg: #2e3018;
    }
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    background: var(--bg); color: var(--text);
    max-width: 940px; margin: 0 auto; padding: 32px 20px;
    line-height: 1.5;
  }
  h1 { font-size: 22px; font-weight: 600; margin-bottom: 4px; }
  .meta { color: var(--text2); font-size: 13px; margin-bottom: 12px; }

  /* --- Global scope bar --- */
  .scope-bar {
    display: flex; gap: 8px; align-items: center; flex-wrap: wrap;
    padding: 10px 16px; margin-bottom: 20px;
    background: var(--card); border: 1px solid var(--border); border-radius: 10px;
    font-size: 13px;
  }
  .scope-bar .label {
    font-weight: 600; color: var(--text2); font-size: 11px;
    text-transform: uppercase; letter-spacing: 0.5px; margin-right: 4px;
  }
  .scope-chip {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 5px 14px; border-radius: 6px; cursor: pointer;
    border: 2px solid transparent; transition: all 0.15s;
    user-select: none; font-size: 13px; font-weight: 500;
  }
  .scope-chip:hover { opacity: 0.85; }
  .scope-chip.active { border-color: currentColor; }
  .scope-chip.chip-all { color: var(--accent); background: var(--accent-bg); }
  .scope-chip.chip-user { color: var(--scope-user); background: var(--scope-user-bg); }
  .scope-chip.chip-project { color: var(--scope-project); background: var(--scope-project-bg); }
  .scope-chip.chip-local { color: var(--scope-local); background: var(--scope-local-bg); }
  .scope-chip.disabled { opacity: 0.3; cursor: default; pointer-events: none; }
  .scope-chip .dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; }
  .scope-chip .path { font-family: 'SF Mono', Menlo, monospace; font-size: 11px; opacity: 0.7; }

  /* --- Badges --- */
  .badges { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 28px; }
  .badge {
    background: var(--badge); border-radius: 6px; padding: 6px 14px;
    font-size: 13px; font-weight: 500; cursor: pointer; transition: opacity 0.15s;
  }
  .badge:hover { opacity: 0.75; }
  .badge strong { color: var(--accent); }

  /* --- Sections --- */
  section {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 10px; margin-bottom: 16px; overflow: hidden;
  }
  .section-header {
    padding: 14px 18px; cursor: pointer; display: flex;
    justify-content: space-between; align-items: center;
    font-weight: 600; font-size: 15px; user-select: none;
  }
  .section-header:hover { background: var(--accent-bg); }
  .section-header .arrow { transition: transform 0.2s; font-size: 12px; color: var(--text2); }
  .section-header.open .arrow { transform: rotate(90deg); }
  .section-body { display: none; border-top: 1px solid var(--border); }
  .section-body.open { display: block; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  td { padding: 8px 16px; border-bottom: 1px solid var(--border); vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  td:nth-child(2) { font-weight: 500; white-space: nowrap; }
  td:last-child { color: var(--text2); }

  /* --- Scope tags (in rows) --- */
  .scope-tag {
    display: inline-block; font-size: 10px; font-weight: 700;
    padding: 3px 8px; border-radius: 4px; text-transform: uppercase;
    letter-spacing: 0.4px; white-space: nowrap; min-width: 52px; text-align: center;
  }
  .scope-user { background: var(--scope-user-bg); color: var(--scope-user); }
  .scope-project { background: var(--scope-project-bg); color: var(--scope-project); }
  .scope-local { background: var(--scope-local-bg); color: var(--scope-local); }

  /* --- Source hints --- */
  .source-hint {
    font-family: 'SF Mono', Menlo, monospace; font-size: 11px;
    color: var(--text2); opacity: 0.7;
  }

  .footer { text-align: center; color: var(--text2); font-size: 12px; margin-top: 32px; }
</style>
</head>
<body>
<h1>Claude Code Inspector</h1>
HTMLHEAD

echo "<p class=\"meta\">Generated: $NOW</p>" >> "$OUT"

# Scope bar - clickable chips
{
  echo '<div class="scope-bar">'
  echo '  <span class="label">Filter</span>'
  echo '  <span class="scope-chip chip-all active" data-scope="all">All</span>'
  echo '  <span class="scope-chip chip-user" data-scope="user"><span class="dot"></span> User <span class="path">~/.claude/</span></span>'
  if [[ -n "$PROJECT_DIR" ]]; then
    echo "  <span class=\"scope-chip chip-project\" data-scope=\"project\"><span class=\"dot\"></span> Project <span class=\"path\">$PROJECT_NAME/.claude/</span></span>"
  else
    echo '  <span class="scope-chip chip-project disabled"><span class="dot"></span> Project</span>'
  fi
  local_exists=""
  [[ -f "$CLAUDE_DIR/settings.local.json" ]] && local_exists="1"
  [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/settings.local.json" ]] && local_exists="1"
  if [[ -n "$local_exists" ]]; then
    echo '  <span class="scope-chip chip-local" data-scope="local"><span class="dot"></span> Local <span class="path">settings.local.json</span></span>'
  else
    echo '  <span class="scope-chip chip-local disabled"><span class="dot"></span> Local</span>'
  fi
  echo '</div>'
} >> "$OUT"

cat >> "$OUT" << BADGES
<div class="badges">
  <span class="badge" data-badge="skills"><strong>$skill_count</strong> Skills</span>
  <span class="badge" data-badge="plugins"><strong>$plugin_count</strong> Plugins</span>
  <span class="badge" data-badge="mcp"><strong>$mcp_count</strong> MCP Servers</span>
  <span class="badge" data-badge="commands"><strong>$command_count</strong> Commands</span>
  <span class="badge" data-badge="hooks"><strong>$hook_count</strong> Hooks</span>
</div>
BADGES

# --- Render sections ---
render_section() {
  local title="$1" open="$2" category="$3"
  local open_class=""
  [[ "$open" == "1" ]] && open_class=" open"
  cat >> "$OUT" << EOF
<section data-category="${category}">
  <div class="section-header${open_class}">
    <span>$title</span><span class="arrow">&#9654;</span>
  </div>
  <div class="section-body${open_class}">
    <table>
EOF
}

# Skills
render_section "Skills" "1" "skills"
collect_skills "user" "$CLAUDE_DIR/skills" >> "$OUT" || true
[[ -n "$PROJECT_DIR" ]] && collect_skills "project" "$PROJECT_DIR/skills" >> "$OUT" || true
echo "</table></div></section>" >> "$OUT"

# Plugins
render_section "Plugins" "0" "plugins"
collect_plugins >> "$OUT" || true
echo "</table></div></section>" >> "$OUT"

# MCP Servers
render_section "MCP Servers" "0" "mcp"
collect_mcp_from "user" "$CLAUDE_DIR/settings.json" >> "$OUT" || true
collect_mcp_from "local" "$CLAUDE_DIR/settings.local.json" >> "$OUT" || true
if [[ -n "$PROJECT_DIR" ]]; then
  collect_mcp_from "project" "$PROJECT_DIR/settings.json" >> "$OUT" || true
  collect_mcp_from "local" "$PROJECT_DIR/settings.local.json" >> "$OUT" || true
fi
echo "</table></div></section>" >> "$OUT"

# Commands
render_section "Commands" "0" "commands"
collect_commands "user" "$CLAUDE_DIR/commands" >> "$OUT" || true
[[ -n "$PROJECT_DIR" ]] && collect_commands "project" "$PROJECT_DIR/commands" >> "$OUT" || true
echo "</table></div></section>" >> "$OUT"

# Hooks
render_section "Hooks" "0" "hooks"
collect_hooks_from "user" "$CLAUDE_DIR/settings.json" >> "$OUT" || true
collect_hooks_from "local" "$CLAUDE_DIR/settings.local.json" >> "$OUT" || true
if [[ -n "$PROJECT_DIR" ]]; then
  collect_hooks_from "project" "$PROJECT_DIR/settings.json" >> "$OUT" || true
  collect_hooks_from "local" "$PROJECT_DIR/settings.local.json" >> "$OUT" || true
fi
echo "</table></div></section>" >> "$OUT"

# Footer + JS
cat >> "$OUT" << 'EOF'
<p class="footer">cc-inspect &middot; /inspect</p>
<script>
// Use event delegation instead of inline onclick (file:// compatibility)
document.addEventListener('click', function(e) {
  // Section toggle
  var header = e.target.closest('.section-header');
  if (header) {
    header.classList.toggle('open');
    header.nextElementSibling.classList.toggle('open');
    return;
  }
  // Badge scroll to section
  var badge = e.target.closest('.badge[data-badge]');
  if (badge) {
    var cat = badge.dataset.badge;
    var section = document.querySelector('section[data-category="' + cat + '"]');
    if (section) {
      var header = section.querySelector('.section-header');
      var body = section.querySelector('.section-body');
      if (header && body && !header.classList.contains('open')) {
        header.classList.add('open');
        body.classList.add('open');
      }
      section.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
    return;
  }
  // Scope filter chips
  var chip = e.target.closest('.scope-chip:not(.disabled)');
  if (chip) {
    var scope = chip.dataset.scope;
    document.querySelectorAll('.scope-chip').forEach(function(c) { c.classList.remove('active'); });
    chip.classList.add('active');
    // Filter rows
    document.querySelectorAll('table tr').forEach(function(tr) {
      if (scope === 'all') { tr.style.display = ''; return; }
      tr.style.display = (tr.dataset.scope === scope) ? '' : 'none';
    });
    // Update badge counts
    document.querySelectorAll('.badge[data-badge]').forEach(function(badge) {
      var cat = badge.dataset.badge;
      var section = document.querySelector('section[data-category="' + cat + '"]');
      if (!section) return;
      var count = 0;
      section.querySelectorAll('table tr').forEach(function(tr) {
        if (scope === 'all' || tr.dataset.scope === scope) count++;
      });
      badge.querySelector('strong').textContent = count;
    });
  }
});
</script>
</body>
</html>
EOF

open "$OUT"
echo "Dashboard opened: $OUT"
