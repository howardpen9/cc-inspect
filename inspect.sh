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

collect_memory() {
  # Scans memory locations and emits one complete <div class="mem-section-body">...</div>
  # containing all groups (sanity warnings, orphans, stale, duplicates, agent sessions, live).
  python3 - "$HOME" "$CLAUDE_DIR" << 'PYEOF' 2>/dev/null || true
import os, sys, json, hashlib, html, time
HOME = sys.argv[1]
CLAUDE_DIR = sys.argv[2]
NOW = time.time()
STALE_DAYS = 30
STALE_SEC = STALE_DAYS * 86400

def human_size(nbytes):
    for unit in ['B','K','M','G','T']:
        if nbytes < 1024:
            if unit == 'B':
                return f'{int(nbytes)}{unit}'
            return f'{nbytes:.1f}{unit}' if nbytes < 10 else f'{int(nbytes)}{unit}'
        nbytes /= 1024
    return f'{nbytes:.1f}P'

def human_age(seconds):
    if seconds is None: return '—'
    if seconds < 60: return 'just now'
    if seconds < 3600: return f'{int(seconds/60)}m ago'
    if seconds < 86400: return f'{int(seconds/3600)}h ago'
    days = int(seconds / 86400)
    if days < 365: return f'{days}d ago'
    return f'{days//365}y ago'

def resolve_cwd(project_dir):
    try:
        entries = os.listdir(project_dir)
    except OSError:
        return None, False
    jsonls = [f for f in entries if f.endswith('.jsonl')]
    if not jsonls:
        return None, False
    for fn in jsonls[:5]:
        try:
            with open(os.path.join(project_dir, fn), 'r', errors='replace') as f:
                for i, line in enumerate(f):
                    if i > 100: break
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    cwd = obj.get('cwd')
                    if cwd:
                        return cwd, True
        except OSError:
            continue
    return None, True

def collect_md_files(memory_dir):
    out = []
    try:
        for name in os.listdir(memory_dir):
            if not name.endswith('.md'): continue
            p = os.path.join(memory_dir, name)
            try:
                st = os.stat(p)
            except OSError:
                continue
            if not os.path.isfile(p): continue
            try:
                with open(p, 'rb') as f:
                    md5 = hashlib.md5(f.read()).hexdigest()
            except OSError:
                md5 = ''
            out.append((p, st.st_mtime, st.st_size, md5))
    except OSError:
        pass
    return out

def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total

def pretty_path(p):
    if not p: return ''
    if p.startswith(HOME):
        return '~' + p[len(HOME):]
    return p

def shell_quote(s):
    # Single-quote for safe shell embedding
    return "'" + s.replace("'", "'\\''") + "'"

# --- Collect entries ---
entries = []

# 1) ~/.claude/projects/*/memory
projects_root = os.path.join(CLAUDE_DIR, 'projects')
if os.path.isdir(projects_root):
    for enc in sorted(os.listdir(projects_root)):
        pdir = os.path.join(projects_root, enc)
        mdir = os.path.join(pdir, 'memory')
        if not os.path.isdir(mdir): continue
        cwd, has_jsonl = resolve_cwd(pdir)
        mds = collect_md_files(mdir)
        try:
            contents = os.listdir(mdir)
        except OSError:
            contents = []
        if not mds and not contents:
            continue
        size = dir_size(mdir)
        latest = max((m[1] for m in mds), default=0)
        if cwd and os.path.isdir(cwd):
            label = os.path.basename(cwd.rstrip('/')) or cwd
            cwd_missing = False
        elif cwd:
            label = os.path.basename(cwd.rstrip('/')) or cwd
            cwd_missing = True
        else:
            parts = enc.strip('-').split('-')
            label = parts[-1] if parts else enc
            cwd_missing = True
        entries.append({
            'scope': 'project',
            'label': label,
            'encoded': enc,
            'cwd': cwd,
            'cwd_missing': cwd_missing,
            'has_jsonl': has_jsonl,
            'mds': mds,
            'size': size,
            'latest': latest,
            'memory_dir': mdir,
        })

# 2) ~/.claude/CLAUDE.md (global)
global_md = os.path.join(CLAUDE_DIR, 'CLAUDE.md')
global_entry = None
if os.path.isfile(global_md):
    try:
        st = os.stat(global_md)
        with open(global_md, 'rb') as f:
            md5 = hashlib.md5(f.read()).hexdigest()
        global_entry = {
            'scope': 'global',
            'label': '~/.claude/CLAUDE.md',
            'encoded': None,
            'cwd': HOME,
            'cwd_missing': False,
            'has_jsonl': True,
            'mds': [(global_md, st.st_mtime, st.st_size, md5)],
            'size': st.st_size,
            'latest': st.st_mtime,
            'memory_dir': global_md,
        }
    except OSError:
        pass

# 3) ~/.claude/agent-memory/*
agent_root = os.path.join(CLAUDE_DIR, 'agent-memory')
if os.path.isdir(agent_root):
    for name in sorted(os.listdir(agent_root)):
        sub = os.path.join(agent_root, name)
        if not os.path.isdir(sub): continue
        mds = collect_md_files(sub)
        size = dir_size(sub)
        latest = max((m[1] for m in mds), default=0)
        entries.append({
            'scope': 'agent-memory',
            'label': name,
            'encoded': None,
            'cwd': sub,
            'cwd_missing': False,
            'has_jsonl': True,
            'mds': mds,
            'size': size,
            'latest': latest,
            'memory_dir': sub,
        })

# --- Duplicate detection: cluster by md5 across ALL entries + global ---
all_entries = entries + ([global_entry] if global_entry else [])
md5_clusters = {}  # md5 -> list of (entry_idx_in_all, md_tuple)
for idx, e in enumerate(all_entries):
    for md in e['mds']:
        md5 = md[3]
        if not md5: continue
        md5_clusters.setdefault(md5, []).append((idx, md))

dup_clusters = []  # list of {hash, files: [(entry_idx, md_tuple), ...]}
for md5, lst in md5_clusters.items():
    if len(lst) >= 2:
        dup_clusters.append({'hash': md5, 'files': lst})

# --- Classify each entry into exactly one primary group ---
# Priority: agent_session > sanity_warning (home) > orphan > stale > live
def classify(e):
    enc = e.get('encoded') or ''
    cwd = e.get('cwd') or ''
    # 1. Agent session
    if '--slock-agents-' in enc or '/.slock/agents/' in cwd:
        return 'agent_session'
    # 2. Sanity: home dir has memory
    if e['scope'] == 'project' and cwd and os.path.normpath(cwd) == os.path.normpath(HOME):
        return 'home_warning'
    # 3. Orphan: cwd missing or unresolvable
    if e['scope'] == 'project' and (e['cwd_missing'] or not e['has_jsonl']):
        return 'orphan'
    # 4. Stale: all MDs > 30d
    if e['mds']:
        if all((NOW - m[1]) > STALE_SEC for m in e['mds']):
            return 'stale'
    else:
        # No MDs at all, but dir exists — treat as stale
        return 'stale'
    # 5. Live
    return 'live'

groups = {
    'home_warning': [],
    'orphan': [],
    'stale': [],
    'agent_session': [],
    'live': [],
}
for e in entries:
    groups[classify(e)].append(e)

# --- HTML rendering helpers ---
def esc(s): return html.escape(str(s))

def row_html(e, show_encoded_hint=False, extra_class=''):
    loc = esc(e['label'])
    path_hint = ''
    if e['scope'] == 'project':
        if e['cwd']:
            path_hint = pretty_path(e['cwd'])
        if show_encoded_hint and e.get('encoded'):
            path_hint = (path_hint + '  ·  ' if path_hint else '') + e['encoded']
    elif e['scope'] == 'agent-memory':
        path_hint = pretty_path(e['memory_dir'])
    elif e['scope'] == 'global':
        path_hint = pretty_path(e['memory_dir'])
    age_txt = human_age(NOW - e['latest']) if e['latest'] else '—'
    size_txt = human_size(e['size'])
    path_html = f'<span class="mem-row-hint">{esc(path_hint)}</span>' if path_hint else ''
    return (
        f'<div class="mem-row {extra_class}">'
        f'<div class="mem-row-main">'
        f'<span class="mem-row-label">{loc}</span>'
        f'{path_html}'
        f'</div>'
        f'<span class="mem-row-size">{esc(size_txt)}</span>'
        f'<span class="mem-row-age">{esc(age_txt)}</span>'
        f'</div>'
    )

def build_archive_cmd(paths):
    # Multi-line shell command that archives paths into ~/.claude-archive/<DATE>/
    if not paths: return ''
    lines = [
        'mkdir -p ~/.claude-archive/$(date +%Y%m%d)',
    ]
    for p in paths:
        lines.append(f'mv {shell_quote(p)} ~/.claude-archive/$(date +%Y%m%d)/')
    return '\n'.join(lines)

def group_header(emoji, title, count, size_bytes, copy_cmd=None, tone='default', open_by_default=False):
    size_txt = human_size(size_bytes) if size_bytes else ''
    size_span = f' · <span class="mem-group-size">{esc(size_txt)}</span>' if size_txt else ''
    copy_btn = ''
    if copy_cmd:
        copy_btn = (
            f'<button class="mem-copy-btn" data-copy-cmd="{esc(copy_cmd)}" '
            f'type="button">Copy archive command</button>'
        )
    open_cls = ' open' if open_by_default else ''
    return (
        f'<div class="mem-group mem-group-{tone}{open_cls}">'
        f'  <div class="mem-group-header">'
        f'    <span class="mem-group-title">{emoji} <strong>{count}</strong> {esc(title)}{size_span}</span>'
        f'    <span class="mem-group-actions">{copy_btn}<span class="mem-chevron">&#9654;</span></span>'
        f'  </div>'
        f'  <div class="mem-group-body">'
    )

def group_close():
    return '  </div></div>'

out_parts = []

# === Group: Sanity warnings ===
warnings = []
for e in groups['home_warning']:
    warnings.append((
        f'Home directory has a memory dir: {esc(pretty_path(e["cwd"] or HOME))} '
        f'<span class="mem-row-hint">({esc(e.get("encoded") or "")})</span>'
    ))
# Scan for other anomalies: entries where encoded path has no segments (just "-")
for e in entries:
    enc = e.get('encoded') or ''
    if e['scope'] == 'project' and enc == '-':
        warnings.append(f'Suspicious empty-path encoded memory dir: <code>{esc(enc)}</code>')

if warnings:
    out_parts.append(group_header(
        '⚠️', 'sanity warnings', len(warnings), 0,
        copy_cmd=None, tone='warn', open_by_default=True,
    ))
    for w in warnings:
        out_parts.append(f'<div class="mem-row mem-row-warn"><div class="mem-row-main">{w}</div></div>')
    out_parts.append(group_close())

# === Group: Orphans ===
orphans = groups['orphan']
if orphans:
    total = sum(e['size'] for e in orphans)
    paths = [e['memory_dir'] for e in orphans]
    cmd = build_archive_cmd(paths)
    out_parts.append(group_header(
        '🛑', 'orphans', len(orphans), total,
        copy_cmd=cmd, tone='orphan', open_by_default=True,
    ))
    out_parts.append('<div class="mem-group-hint">Project dirs no longer exist or sessions can\'t be resolved. Archive is reversible (moves to ~/.claude-archive/YYYYMMDD/).</div>')
    # Sort by size desc
    for e in sorted(orphans, key=lambda x: x['size'], reverse=True):
        out_parts.append(row_html(e, show_encoded_hint=True))
    out_parts.append(group_close())

# === Group: Stale ===
stale = groups['stale']
if stale:
    total = sum(e['size'] for e in stale)
    paths = [e['memory_dir'] for e in stale]
    cmd = build_archive_cmd(paths)
    out_parts.append(group_header(
        '🕐', f'stale (>{STALE_DAYS}d)', len(stale), total,
        copy_cmd=cmd, tone='stale', open_by_default=False,
    ))
    out_parts.append('<div class="mem-group-hint">Project still exists but memory hasn\'t been touched in over 30 days. Archive to reset.</div>')
    for e in sorted(stale, key=lambda x: x['size'], reverse=True):
        out_parts.append(row_html(e))
    out_parts.append(group_close())

# === Group: Duplicates (secondary, cross-dir) ===
if dup_clusters:
    saveable = 0
    for c in dup_clusters:
        # saveable = size of (n-1) copies
        sz = c['files'][0][1][2]  # size of first file (they're identical)
        saveable += sz * (len(c['files']) - 1)

    out_parts.append(group_header(
        '👯', 'duplicate clusters', len(dup_clusters), saveable,
        copy_cmd=None, tone='dup', open_by_default=False,
    ))
    out_parts.append('<div class="mem-group-hint">Same file content appears in multiple memory dirs. Dedupe keeps the newest copy.</div>')

    # sort clusters by saveable size desc
    dup_clusters.sort(key=lambda c: c['files'][0][1][2] * (len(c['files']) - 1), reverse=True)
    for c in dup_clusters:
        files = c['files']  # list of (entry_idx_in_all, (path, mtime, size, md5))
        # Find newest mtime -> keep; others -> rm
        files_sorted = sorted(files, key=lambda f: f[1][1], reverse=True)
        newest = files_sorted[0]
        to_remove = files_sorted[1:]
        rm_cmd = '\n'.join(f'rm {shell_quote(f[1][0])}' for f in to_remove)

        # Display info
        first_path = files[0][1][0]
        fname = os.path.basename(first_path)
        fsize = human_size(files[0][1][2])
        dirs_list = []
        for (eidx, md) in files:
            e = all_entries[eidx]
            dirs_list.append(pretty_path(os.path.dirname(md[0])))
        dirs_txt = ', '.join(dirs_list)
        short_hash = c['hash'][:8]

        out_parts.append(
            f'<div class="mem-row mem-dup-row">'
            f'<div class="mem-row-main">'
            f'<span class="mem-row-label">{esc(fname)} <span class="mem-row-hint">({short_hash})</span></span>'
            f'<span class="mem-row-hint">appears in: {esc(dirs_txt)}</span>'
            f'</div>'
            f'<span class="mem-row-size">{esc(fsize)} &times; {len(files)}</span>'
            f'<button class="mem-copy-btn mem-copy-small" data-copy-cmd="{esc(rm_cmd)}" type="button">Copy dedupe</button>'
            f'</div>'
        )
    out_parts.append(group_close())

# === Group: Agent sessions ===
agents = groups['agent_session']
if agents:
    total = sum(e['size'] for e in agents)
    paths = [e['memory_dir'] for e in agents]
    cmd = build_archive_cmd(paths)
    out_parts.append(group_header(
        '🤖', 'agent sessions', len(agents), total,
        copy_cmd=cmd, tone='agent', open_by_default=False,
    ))
    out_parts.append('<div class="mem-group-hint">Transient per-agent memories from <code>.slock/agents/*</code>. Usually safe to archive in bulk if agents aren\'t running.</div>')
    for e in sorted(agents, key=lambda x: x['size'], reverse=True):
        out_parts.append(row_html(e, show_encoded_hint=True))
    out_parts.append(group_close())

# === Group: Global + Live (healthy) ===
live = groups['live']
# Global always rendered in its own mini-group if present
if global_entry:
    out_parts.append(group_header(
        '📌', 'global user memory', 1, global_entry['size'],
        copy_cmd=None, tone='live', open_by_default=False,
    ))
    out_parts.append(row_html(global_entry))
    out_parts.append(group_close())

if live:
    total = sum(e['size'] for e in live)
    out_parts.append(group_header(
        '✨', 'live (healthy)', len(live), total,
        copy_cmd=None, tone='live', open_by_default=False,
    ))
    for e in sorted(live, key=lambda x: x['size'], reverse=True):
        out_parts.append(row_html(e))
    out_parts.append(group_close())

# Summary counts for the top summary line (consumed by outer bash)
counts = {
    'warnings': len(warnings),
    'orphan': len(groups['orphan']),
    'stale': len(groups['stale']),
    'duplicate': len(dup_clusters),
    'agent': len(groups['agent_session']),
    'live': len(live) + (1 if global_entry else 0),
}
# Emit a marker line bash can grep for counts
print(f'<!--MEMCOUNTS:{json.dumps(counts)}-->')
print(''.join(out_parts))
PYEOF
}

count_memory() {
  # Memory no longer uses a flat-count badge in the summary bar.
  # Still compute a rough total for backwards callers that might reference it.
  local c=0
  if [[ -d "$CLAUDE_DIR/projects" ]]; then
    local pc=$(find "$CLAUDE_DIR/projects" -mindepth 2 -maxdepth 2 -name memory -type d 2>/dev/null | wc -l | tr -d ' ')
    c=$((c + pc))
  fi
  [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && c=$((c + 1))
  if [[ -d "$CLAUDE_DIR/agent-memory" ]]; then
    local ac=$(find "$CLAUDE_DIR/agent-memory" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    c=$((c + ac))
  fi
  echo "$c"
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
memory_count=$(count_memory)

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
    --scope-mem: #8a6a8a; --scope-mem-bg: #f0e8f0;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #1a1816; --card: #242220; --border: #3a3632;
      --text: #e8e4de; --text2: #9b9590; --accent: #e07850;
      --accent-bg: #2a2018; --badge: #2e2a26;
      --scope-user: #d5c4a1; --scope-user-bg: #3c3428;
      --scope-project: #83a598; --scope-project-bg: #1e3a30;
      --scope-local: #b8bb26; --scope-local-bg: #2e3018;
      --scope-mem: #c8a2c8; --scope-mem-bg: #3a2a3a;
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
  .scope-mem { background: var(--scope-mem-bg); color: var(--scope-mem); }

  /* --- Memory section: cleanup recommendation engine --- */
  .mem-summary {
    display: flex; gap: 8px; align-items: center; flex-wrap: wrap;
    padding: 12px 18px; border-bottom: 1px solid var(--border);
    background: var(--bg); font-size: 12px; color: var(--text2);
  }
  .mem-summary .mem-pill {
    display: inline-flex; align-items: center; gap: 5px;
    padding: 3px 10px; border-radius: 20px; background: var(--badge);
    font-weight: 500;
  }
  .mem-summary .mem-pill strong { color: var(--text); font-weight: 700; }
  .mem-summary .mem-pill-warn { background: var(--accent-bg); color: var(--accent); }
  .mem-summary .mem-pill-warn strong { color: var(--accent); }
  .mem-summary .mem-pill-live { background: var(--scope-local-bg); color: var(--scope-local); }
  .mem-summary .mem-pill-live strong { color: var(--scope-local); }
  .mem-summary .mem-empty { font-style: italic; opacity: 0.7; }

  .mem-groups { padding: 6px 12px 14px; }
  .mem-group {
    border: 1px solid var(--border); border-radius: 8px;
    margin: 8px 0; background: var(--bg); overflow: hidden;
  }
  .mem-group-header {
    display: flex; justify-content: space-between; align-items: center;
    padding: 10px 14px; cursor: pointer; user-select: none;
    font-size: 13px; gap: 10px;
  }
  .mem-group-header:hover { background: var(--badge); }
  .mem-group-title { display: flex; align-items: center; gap: 6px; flex: 1; }
  .mem-group-title strong { color: var(--text); font-size: 14px; }
  .mem-group-size { font-family: 'SF Mono', Menlo, monospace; color: var(--text2); font-size: 12px; }
  .mem-group-actions { display: flex; align-items: center; gap: 8px; }
  .mem-chevron { transition: transform 0.2s; font-size: 10px; color: var(--text2); }
  .mem-group.open .mem-chevron { transform: rotate(90deg); }
  .mem-group-body { display: none; padding: 4px 14px 10px; border-top: 1px solid var(--border); }
  .mem-group.open .mem-group-body { display: block; }
  .mem-group-hint {
    font-size: 12px; color: var(--text2); padding: 6px 2px 8px;
    font-style: italic;
  }
  .mem-group-hint code {
    font-family: 'SF Mono', Menlo, monospace; font-size: 11px;
    background: var(--badge); padding: 1px 5px; border-radius: 3px;
    font-style: normal;
  }

  /* group tones */
  .mem-group-warn { border-color: var(--accent); }
  .mem-group-warn .mem-group-title strong { color: var(--accent); }
  .mem-group-orphan { border-color: var(--accent); }
  .mem-group-orphan .mem-group-title strong { color: var(--accent); }
  .mem-group-stale .mem-group-title strong { color: var(--scope-user); }
  .mem-group-dup .mem-group-title strong { color: var(--scope-mem); }
  .mem-group-agent { opacity: 0.9; }
  .mem-group-agent .mem-group-title strong { color: var(--text2); }
  .mem-group-live .mem-group-title strong { color: var(--scope-local); }

  /* rows */
  .mem-row {
    display: flex; align-items: center; gap: 12px;
    padding: 7px 2px; border-bottom: 1px dashed var(--border);
    font-size: 12px;
  }
  .mem-row:last-child { border-bottom: none; }
  .mem-row-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .mem-row-label { font-weight: 500; color: var(--text); word-break: break-word; }
  .mem-row-hint {
    font-family: 'SF Mono', Menlo, monospace; font-size: 10.5px;
    color: var(--text2); opacity: 0.75; word-break: break-all;
  }
  .mem-row-size {
    font-family: 'SF Mono', Menlo, monospace; font-size: 11px;
    color: var(--text2); white-space: nowrap; min-width: 50px; text-align: right;
  }
  .mem-row-age {
    font-size: 11px; color: var(--text2); white-space: nowrap;
    min-width: 70px; text-align: right;
  }
  .mem-row-warn { color: var(--accent); }
  .mem-dup-row { gap: 10px; }

  /* copy button */
  .mem-copy-btn {
    font-family: inherit; font-size: 11px; font-weight: 500;
    padding: 4px 10px; border-radius: 5px; cursor: pointer;
    background: var(--accent-bg); color: var(--accent);
    border: 1px solid var(--accent);
    transition: all 0.15s;
  }
  .mem-copy-btn:hover { background: var(--accent); color: #fff; }
  .mem-copy-btn.copied { background: var(--scope-local-bg); color: var(--scope-local); border-color: var(--scope-local); }
  .mem-copy-small { padding: 3px 8px; font-size: 10.5px; }

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

# Memory (cleanup recommendation engine — groups instead of flat table)
MEM_HTML=$(collect_memory || true)
# Extract counts marker (if present) for summary pills
MEM_COUNTS_JSON=$(printf '%s\n' "$MEM_HTML" | grep -o '<!--MEMCOUNTS:.*-->' | head -n1 | sed -e 's/^<!--MEMCOUNTS://' -e 's/-->$//')
MEM_BODY=$(printf '%s\n' "$MEM_HTML" | grep -v '<!--MEMCOUNTS:')

# Parse counts (fallback to 0s if missing)
if [[ -n "$MEM_COUNTS_JSON" ]]; then
  read -r MC_WARN MC_ORPHAN MC_STALE MC_DUP MC_AGENT MC_LIVE <<<"$(python3 -c "
import json,sys
try:
    d = json.loads('''$MEM_COUNTS_JSON''')
    print(d.get('warnings',0), d.get('orphan',0), d.get('stale',0), d.get('duplicate',0), d.get('agent',0), d.get('live',0))
except Exception:
    print(0,0,0,0,0,0)
")"
else
  MC_WARN=0; MC_ORPHAN=0; MC_STALE=0; MC_DUP=0; MC_AGENT=0; MC_LIVE=0
fi

{
  echo '<section data-category="memory">'
  echo '  <div class="section-header">'
  echo '    <span>Memory</span><span class="arrow">&#9654;</span>'
  echo '  </div>'
  echo '  <div class="section-body">'
  echo '    <div class="mem-summary">'
  if [[ "$MC_WARN" -gt 0 ]]; then
    echo "      <span class=\"mem-pill mem-pill-warn\">⚠️ <strong>$MC_WARN</strong> warning$([[ $MC_WARN -ne 1 ]] && echo s)</span>"
  fi
  if [[ "$MC_ORPHAN" -gt 0 ]]; then
    echo "      <span class=\"mem-pill mem-pill-warn\">🛑 <strong>$MC_ORPHAN</strong> orphan$([[ $MC_ORPHAN -ne 1 ]] && echo s)</span>"
  fi
  if [[ "$MC_STALE" -gt 0 ]]; then
    echo "      <span class=\"mem-pill\">🕐 <strong>$MC_STALE</strong> stale</span>"
  fi
  if [[ "$MC_DUP" -gt 0 ]]; then
    echo "      <span class=\"mem-pill\">👯 <strong>$MC_DUP</strong> dup cluster$([[ $MC_DUP -ne 1 ]] && echo s)</span>"
  fi
  if [[ "$MC_AGENT" -gt 0 ]]; then
    echo "      <span class=\"mem-pill\">🤖 <strong>$MC_AGENT</strong> agent session$([[ $MC_AGENT -ne 1 ]] && echo s)</span>"
  fi
  if [[ "$MC_LIVE" -gt 0 ]]; then
    echo "      <span class=\"mem-pill mem-pill-live\">✨ <strong>$MC_LIVE</strong> live</span>"
  fi
  if [[ "$MC_WARN" -eq 0 && "$MC_ORPHAN" -eq 0 && "$MC_STALE" -eq 0 && "$MC_DUP" -eq 0 && "$MC_AGENT" -eq 0 && "$MC_LIVE" -eq 0 ]]; then
    echo '      <span class="mem-empty">No memory directories found.</span>'
  fi
  echo '    </div>'
  echo '    <div class="mem-groups">'
  printf '%s\n' "$MEM_BODY"
  echo '    </div>'
  echo '  </div>'
  echo '</section>'
} >> "$OUT"

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
  // Scope filter chips (global).
  var chip = e.target.closest('.scope-chip:not(.disabled)');
  if (chip) {
    var scope = chip.dataset.scope;
    document.querySelectorAll('.scope-chip').forEach(function(c) { c.classList.remove('active'); });
    chip.classList.add('active');
    // Filter rows in standard table sections (Skills / Plugins / MCP / Commands / Hooks)
    document.querySelectorAll('table tr').forEach(function(tr) {
      if (scope === 'all') { tr.style.display = ''; return; }
      tr.style.display = (tr.dataset.scope === scope) ? '' : 'none';
    });
    // Update badge counts (memory has no flat badge anymore)
    document.querySelectorAll('.badge[data-badge]').forEach(function(badge) {
      var cat = badge.dataset.badge;
      var section = document.querySelector('section[data-category="' + cat + '"]');
      if (!section) return;
      var count = 0;
      section.querySelectorAll('table tr').forEach(function(tr) {
        if (scope === 'all' || tr.dataset.scope === scope) count++;
      });
      var s = badge.querySelector('strong');
      if (s) s.textContent = count;
    });
    return;
  }
  // Memory group expand/collapse
  var memHeader = e.target.closest('.mem-group-header');
  if (memHeader && !e.target.closest('.mem-copy-btn')) {
    memHeader.parentElement.classList.toggle('open');
    return;
  }
  // Copy-to-clipboard buttons
  var copyBtn = e.target.closest('.mem-copy-btn');
  if (copyBtn) {
    e.stopPropagation();
    var cmd = copyBtn.dataset.copyCmd || '';
    copyToClipboard(cmd, copyBtn);
    return;
  }
});

// --- Clipboard helper (works from file://) ---
function copyToClipboard(text, btn) {
  var done = function() { flashCopied(btn); };
  var fail = function() {
    // Fallback via hidden textarea
    try {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
      done();
    } catch (err) {
      if (btn) { var orig = btn.textContent; btn.textContent = 'Copy failed'; setTimeout(function() { btn.textContent = orig; }, 1500); }
    }
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, fail);
  } else {
    fail();
  }
}
function flashCopied(btn) {
  if (!btn) return;
  var orig = btn.textContent;
  btn.textContent = '\u2713 Copied';
  btn.classList.add('copied');
  setTimeout(function() {
    btn.textContent = orig;
    btn.classList.remove('copied');
  }, 1500);
}
</script>
</body>
</html>
EOF

open "$OUT"
echo "Dashboard opened: $OUT"
