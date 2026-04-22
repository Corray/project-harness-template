#!/usr/bin/env python3
"""
Harness Dashboard Generator

读取 ~/.claude/harness-projects.yaml 的注册表，聚合每个项目的
docs/workspace/.harness-metrics/ 数据，生成单文件 HTML 看板。

用法：
    python3 build.py                    # 生成 HTML 到默认位置
    python3 build.py --open             # 生成并用浏览器打开
    python3 build.py --output <path>    # 自定义输出路径

零外部依赖（纯 stdlib；有 pyyaml 就用，没有就走回退解析器）。
"""
import argparse
import json
import os
import re
import subprocess
import sys
import webbrowser
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

CONFIG = Path.home() / ".claude" / "harness-projects.yaml"
DEFAULT_OUTPUT = Path.home() / ".claude" / "harness-dashboard" / "dashboard.html"


# ---------------- YAML 解析（回退式） ----------------

def parse_yaml_simple(path: Path):
    """优先用 pyyaml；没装就按本脚本自己控制的结构做简易解析。"""
    if not path.exists():
        return {"projects": []}
    try:
        import yaml  # type: ignore
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
            return data if "projects" in data else {"projects": []}
    except ImportError:
        pass

    projects = []
    current = None
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip()
            if line.startswith("  - name:"):
                if current:
                    projects.append(current)
                current = {"name": line.split(":", 1)[1].strip().strip('"\'')}
            elif current and line.startswith("    "):
                key_val = line.strip()
                if ":" in key_val:
                    k, v = key_val.split(":", 1)
                    current[k.strip()] = v.strip().strip('"\'')
        if current:
            projects.append(current)
    return {"projects": projects}


# ---------------- 事件读取 ----------------

def read_jsonl(path: Path):
    if not path.exists():
        return []
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return entries


def load_events(project_path: Path, subdir: str):
    base = project_path / "docs" / "workspace" / ".harness-metrics" / subdir
    if not base.exists():
        return []
    events = []
    for jsonl in sorted(base.glob("*.jsonl")):
        events.extend(read_jsonl(jsonl))
    return events


# ---------------- Knowledge 更新（git log + impl 事件）----------------

def git_knowledge_changes(project_path: Path, days: int = 30):
    """用 git log 找出 knowledge/ 下最近 N 天有改动的文件。"""
    knowledge_dirs = []
    for candidate in ("knowledge", ".claude/knowledge"):
        p = project_path / candidate
        if p.exists():
            knowledge_dirs.append(candidate)
    if not knowledge_dirs:
        return []

    try:
        cmd = [
            "git", "-C", str(project_path),
            "log", f"--since={days}.days.ago",
            "--name-status",
            "--pretty=format:COMMIT%x09%H%x09%ct%x09%an",
            "--",
        ] + knowledge_dirs
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=10)
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return []

    # 解析：commit 行 + 紧跟的 name-status 行（A/M/D + path）
    changes = {}  # file -> {"file": ..., "last_updated": iso, "developer": name, "status": latest, "commits": n}
    current_commit = None
    current_ts = None
    current_dev = None
    for raw in out.splitlines():
        if raw.startswith("COMMIT\t"):
            parts = raw.split("\t")
            if len(parts) >= 4:
                current_commit = parts[1]
                try:
                    current_ts = datetime.utcfromtimestamp(int(parts[2])).isoformat(timespec="seconds")
                except ValueError:
                    current_ts = None
                current_dev = parts[3]
            continue
        if not raw.strip() or current_ts is None:
            continue
        parts = raw.split("\t")
        if len(parts) < 2:
            continue
        status, path = parts[0], parts[1]
        if not path.endswith(".md"):
            continue
        if path in changes:
            changes[path]["commits"] += 1
            # 保留最新（最早遍历到的，因为 git log 默认倒序）
        else:
            changes[path] = {
                "file": path,
                "last_updated": current_ts,
                "developer": current_dev,
                "status": status,
                "commits": 1,
            }
    return sorted(changes.values(), key=lambda x: x["last_updated"] or "", reverse=True)


def extract_knowledge_suggestions(impl_events):
    """impl 事件里若带 knowledge_updated/knowledge_suggested 字段则收集。"""
    out = []
    for e in impl_events:
        updated = e.get("knowledge_updated") or e.get("knowledge_suggested")
        if not updated:
            continue
        if isinstance(updated, str):
            updated = [updated]
        for item in updated:
            if isinstance(item, dict):
                out.append({
                    "file": item.get("file", ""),
                    "reason": item.get("reason", ""),
                    "time": e.get("time", ""),
                    "developer": e.get("developer", ""),
                    "accepted": item.get("accepted", True),
                })
            else:
                out.append({
                    "file": str(item),
                    "reason": "",
                    "time": e.get("time", ""),
                    "developer": e.get("developer", ""),
                    "accepted": True,
                })
    return out


# ---------------- 命令反馈（docs/feedback/commands + 事件流）----------------

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n(.*)$", re.DOTALL)


def parse_markdown_frontmatter(path: Path):
    """解析 YAML frontmatter（仅支持扁平 key: value）。"""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None, ""
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None, text
    fm_raw, body = m.group(1), m.group(2)
    fm = {}
    for line in fm_raw.splitlines():
        if ":" not in line or line.startswith(" "):
            continue
        k, v = line.split(":", 1)
        fm[k.strip()] = v.strip().strip('"\'')
    return fm, body


def load_command_feedback(project_path: Path):
    dir_ = project_path / "docs" / "feedback" / "commands"
    if not dir_.exists():
        return []
    items = []
    for md in sorted(dir_.glob("*.md"), reverse=True):
        fm, body = parse_markdown_frontmatter(md)
        if fm is None:
            continue
        title = ""
        for line in body.splitlines():
            if line.startswith("# "):
                title = line[2:].strip()
                break
        items.append({
            "file": str(md.relative_to(project_path)),
            "command": fm.get("command", ""),
            "developer": fm.get("developer", ""),
            "created_at": fm.get("created_at", ""),
            "severity": fm.get("severity", ""),
            "status": fm.get("status", "open"),
            "title": title,
        })
    return items


# ---------------- 时间工具 ----------------

def parse_time(iso):
    if not iso:
        return None
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).replace(tzinfo=None)
    except (ValueError, AttributeError):
        return None


def in_last_days(iso, days):
    t = parse_time(iso)
    if t is None:
        return False
    return t >= datetime.utcnow() - timedelta(days=days)


def in_range(iso, start, end):
    t = parse_time(iso)
    if t is None:
        return False
    return start <= t < end


# ---------------- 聚合逻辑 ----------------

def aggregate_project(project):
    path = Path(os.path.expanduser(project["path"]))
    if not path.exists():
        return {"error": f"项目路径不存在：{path}"}

    impl = load_events(path, "impl")
    adversarial = load_events(path, "adversarial")
    run_tasks = load_events(path, "run-tasks")
    knowledge_hits = load_events(path, "knowledge-hits")

    impl_30d = [e for e in impl if in_last_days(e.get("time"), 30)]

    # --- 核心指标 ---
    total = len(impl_30d)
    first_pass = sum(1 for e in impl_30d if e.get("first_pass"))
    heal_sum = sum(e.get("heal_cycles", 0) for e in impl_30d)
    human = sum(1 for e in impl_30d if e.get("human_intervention"))

    metrics = {
        "impl_count_30d": total,
        "first_pass_rate": (first_pass / total * 100) if total else None,
        "avg_heal_cycles": (heal_sum / total) if total else None,
        "human_intervention_rate": (human / total * 100) if total else None,
    }

    # --- 14 天趋势 ---
    trend = []
    for days_ago in range(13, -1, -1):
        day_start = datetime.utcnow() - timedelta(days=days_ago + 1)
        day_end = datetime.utcnow() - timedelta(days=days_ago)
        day_events = [e for e in impl if in_range(e.get("time"), day_start, day_end)]
        if day_events:
            fp = sum(1 for e in day_events if e.get("first_pass"))
            rate = fp / len(day_events) * 100
        else:
            rate = None
        trend.append({
            "date": day_end.strftime("%Y-%m-%d"),
            "rate": rate,
            "count": len(day_events),
        })

    # --- Knowledge 命中 ---
    kh_counter = Counter()
    for e in knowledge_hits:
        if in_last_days(e.get("time"), 30):
            kh_counter[e.get("file", "unknown")] += 1

    # 零命中：扫描项目 knowledge/ 下所有 md，找不在 counter 里的
    all_knowledge = []
    knowledge_root = path / "knowledge"
    if knowledge_root.exists():
        for md in sorted(knowledge_root.rglob("*.md")):
            rel = md.relative_to(knowledge_root)
            all_knowledge.append(str(rel).replace(os.sep, "/"))
    hit_keys_norm = {k.replace(os.sep, "/") for k in kh_counter.keys()}
    zero_hit = [k for k in all_knowledge if k not in hit_keys_norm]

    # --- 对抗评估汇总 ---
    adv_summary = []
    for e in adversarial:
        adv_summary.append({
            "time": e.get("time", ""),
            "branch": e.get("branch", "unknown"),
            "score": e.get("total_score") or e.get("score"),
            "must_fix": e.get("must_fix_count", 0) or e.get("must_fix", 0),
            "recommendation": e.get("recommendation") or e.get("verdict") or "unknown",
            "reject_reasons": e.get("reject_reasons", []),
            "report_path": e.get("report_path", ""),
            "oracle": bool(e.get("oracle")),
            "evaluator": e.get("evaluator", "solo"),
            "peer_score": e.get("peer_score"),
            "agreement_delta": e.get("agreement_delta"),
            "disagreement": bool(e.get("disagreement")),
            "sprint": e.get("sprint", ""),
            "override_by": e.get("override_by"),
            "override_reason": e.get("override_reason"),
        })
    adv_summary.sort(key=lambda x: x["time"], reverse=True)

    # --- Oracle 评估分组（按 sprint + 时间窗聚合 A/B/aggregate）---
    oracle_events = [e for e in adversarial if e.get("oracle")]
    oracle_reviews = []
    # 按 sprint 分组；同一 sprint 内按 time 贴近（±2 分钟）聚合成一次 review
    by_sprint = {}
    for e in oracle_events:
        sp = e.get("sprint", "unknown")
        by_sprint.setdefault(sp, []).append(e)
    for sp, events in by_sprint.items():
        events.sort(key=lambda x: x.get("time", ""))
        # 简单贪婪：每次找到 aggregate 事件就与它前面相邻的 A/B 组成一次 review
        seen_idx = set()
        for i, agg in enumerate(events):
            if agg.get("evaluator") != "aggregate" or i in seen_idx:
                continue
            a_evt, b_evt = None, None
            # 向前最多看 5 条找 A 和 B
            for j in range(max(0, i - 5), i):
                if j in seen_idx:
                    continue
                ev = events[j]
                if ev.get("evaluator") == "A" and a_evt is None:
                    a_evt = ev
                    seen_idx.add(j)
                elif ev.get("evaluator") == "B" and b_evt is None:
                    b_evt = ev
                    seen_idx.add(j)
            seen_idx.add(i)
            oracle_reviews.append({
                "sprint": sp,
                "time": agg.get("time", ""),
                "branch": agg.get("branch", ""),
                "mode": "serial" if agg.get("serial_emulated") else "three-session",
                "rule": agg.get("rule", "strict-AND"),
                "final_verdict": agg.get("final_verdict") or agg.get("verdict") or "unknown",
                "a_score": (a_evt or {}).get("score") or agg.get("a_score"),
                "b_score": (b_evt or {}).get("score") or agg.get("b_score"),
                "a_verdict": (a_evt or {}).get("verdict"),
                "b_verdict": (b_evt or {}).get("verdict"),
                "disagreement": bool(agg.get("disagreement")),
                "must_fix_union": agg.get("must_fix_union", 0),
                "override_by": agg.get("override_by"),
                "override_reason": agg.get("override_reason"),
            })
    oracle_reviews.sort(key=lambda x: x.get("time", ""), reverse=True)
    oracle_stats = {
        "review_count": len(oracle_reviews),
        "disagreement_count": sum(1 for r in oracle_reviews if r["disagreement"]),
        "override_count": sum(1 for r in oracle_reviews if r.get("override_by")),
        "reject_count": sum(1 for r in oracle_reviews if (r.get("final_verdict") or "").startswith("reject")),
    }

    # --- 并行 Worker 统计（impl 事件 + run-tasks/parallel-*.jsonl）---
    parallel_impl_30d = [e for e in impl_30d if (e.get("parallel") or 1) > 1]
    parallel_waves = [e for e in run_tasks if e.get("wave") is not None and "dispatched" in e]
    parallel_waves_30d = [e for e in parallel_waves if in_last_days(e.get("time"), 30)]
    parallel_stats = {
        "parallel_tasks_30d": len(parallel_impl_30d),
        "parallel_tasks_share": (len(parallel_impl_30d) / total * 100) if total else None,
        "max_parallel": max((e.get("parallel") or 1 for e in impl_30d), default=1),
        "wave_count_30d": len(parallel_waves_30d),
        "total_dispatched": sum(e.get("dispatched", 0) for e in parallel_waves_30d),
        "total_succeeded": sum(e.get("succeeded", 0) for e in parallel_waves_30d),
        "total_failed": sum(e.get("failed", 0) for e in parallel_waves_30d),
        "total_merge_conflicts": sum(e.get("merge_conflicts", 0) for e in parallel_waves_30d),
        "recent_waves": sorted(parallel_waves_30d, key=lambda x: x.get("time", ""), reverse=True)[:20],
    }

    # --- 最近 impl 时间线（含 run-tasks 的子任务）---
    timeline_events = impl_30d + [e for e in run_tasks if in_last_days(e.get("time"), 30)]
    timeline_events.sort(key=lambda x: x.get("time", ""), reverse=True)
    timeline = []
    for e in timeline_events[:50]:
        timeline.append({
            "time": e.get("time", ""),
            "developer": e.get("developer", ""),
            "task_desc": e.get("task_desc") or e.get("task_id", ""),
            "task_size": e.get("task_size", ""),
            "role": e.get("role", ""),
            "heal_cycles": e.get("heal_cycles", 0),
            "duration_minutes": e.get("duration_minutes"),
            "commit_hash": e.get("commit_hash", ""),
            "human_intervention": e.get("human_intervention", False),
            "red_lines_triggered": e.get("red_lines_triggered", []),
        })

    # --- Knowledge 更新（git log + impl 事件的 knowledge_updated）---
    git_updates = git_knowledge_changes(path, days=30)
    impl_updates = extract_knowledge_suggestions(
        [e for e in impl if in_last_days(e.get("time"), 30)]
    )
    # 合并：按 file 去重，git 优先（有时间戳更可信）
    updates_by_file = {u["file"]: u for u in git_updates}
    for u in impl_updates:
        f = u["file"]
        if f in updates_by_file:
            # 附加建议理由
            existing = updates_by_file[f]
            if u.get("reason") and "reason" not in existing:
                existing["reason"] = u["reason"]
        else:
            updates_by_file[f] = {
                "file": f,
                "last_updated": u.get("time", ""),
                "developer": u.get("developer", ""),
                "status": "S",   # suggested
                "commits": 0,
                "reason": u.get("reason", ""),
            }
    knowledge_updates = sorted(
        updates_by_file.values(),
        key=lambda x: x.get("last_updated", "") or "",
        reverse=True,
    )

    # --- 命令反馈 ---
    cmd_feedback = load_command_feedback(path)
    cmd_feedback_by_cmd = Counter(f["command"] for f in cmd_feedback if f.get("status") == "open")
    cmd_feedback_by_severity = Counter(f["severity"] for f in cmd_feedback if f.get("status") == "open")

    return {
        "metrics": metrics,
        "knowledge_top": kh_counter.most_common(15),
        "knowledge_zero_hit": zero_hit,
        "knowledge_total": len(all_knowledge),
        "knowledge_updates": knowledge_updates[:30],
        "knowledge_updates_count": len(knowledge_updates),
        "adversarial": adv_summary,
        "oracle_reviews": oracle_reviews,
        "oracle_stats": oracle_stats,
        "parallel_stats": parallel_stats,
        "timeline": timeline,
        "trend": trend,
        "command_feedback": cmd_feedback,
        "command_feedback_by_cmd": dict(cmd_feedback_by_cmd),
        "command_feedback_by_severity": dict(cmd_feedback_by_severity),
    }


# ---------------- HTML 模板 ----------------

HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>Harness Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
* { box-sizing: border-box; }
body { margin:0; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC',sans-serif; background:#f1f5f9; color:#0f172a; }
.app { display:flex; height:100vh; overflow:hidden; }
.sidebar { width:260px; background:#0f172a; color:#e2e8f0; padding:24px 16px; overflow-y:auto; flex-shrink:0; }
.sidebar h1 { margin:0 0 4px 0; font-size:15px; font-weight:600; }
.sidebar .sub { font-size:11px; color:#64748b; margin-bottom:20px; }
.project-list { list-style:none; padding:0; margin:0; }
.project-list li { padding:10px 12px; border-radius:6px; cursor:pointer; font-size:13px; margin-bottom:2px; display:flex; justify-content:space-between; align-items:center; }
.project-list li:hover { background:#1e293b; }
.project-list li.active { background:#3b82f6; color:#fff; }
.project-list .badge { font-size:11px; opacity:0.7; font-variant-numeric:tabular-nums; }
.main { flex:1; padding:28px 36px; overflow-y:auto; }
.header { display:flex; justify-content:space-between; align-items:baseline; margin-bottom:18px; gap:20px; }
.header h2 { margin:0; font-size:22px; }
.header .path { color:#64748b; font-size:12px; font-family:'SF Mono',Menlo,Consolas,monospace; margin-top:4px; }
.tabs { display:flex; gap:2px; margin-bottom:24px; border-bottom:1px solid #e2e8f0; }
.tab { padding:10px 16px; cursor:pointer; border:none; background:none; font-size:13px; color:#64748b; border-bottom:2px solid transparent; transition:all .15s; }
.tab:hover { color:#0f172a; }
.tab.active { color:#3b82f6; border-bottom-color:#3b82f6; }
.tab-panel { display:none; }
.tab-panel.active { display:block; }
.grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:14px; margin-bottom:18px; }
.card { background:white; padding:20px; border-radius:10px; box-shadow:0 1px 2px rgba(15,23,42,0.06); }
.card h3 { margin:0 0 12px 0; font-size:12px; color:#64748b; text-transform:uppercase; letter-spacing:.05em; font-weight:600; }
.metric { font-size:34px; font-weight:700; color:#0f172a; line-height:1; font-variant-numeric:tabular-nums; }
.metric .unit { font-size:14px; color:#64748b; font-weight:400; margin-left:4px; }
.metric-sub { font-size:12px; color:#64748b; margin-top:6px; }
.good { color:#059669; }
.warn { color:#d97706; }
.bad { color:#dc2626; }
.muted { color:#94a3b8; }
.chart-card { grid-column:1/-1; background:white; padding:20px; border-radius:10px; box-shadow:0 1px 2px rgba(15,23,42,0.06); }
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { text-align:left; padding:10px 12px; border-bottom:1px solid #f1f5f9; }
th { font-size:11px; text-transform:uppercase; color:#64748b; font-weight:600; letter-spacing:.05em; }
tr:hover td { background:#f8fafc; }
.pill { display:inline-block; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:500; white-space:nowrap; }
.pill-small { background:#e0e7ff; color:#3730a3; }
.pill-large { background:#fef3c7; color:#92400e; }
.pill-approve { background:#d1fae5; color:#065f46; }
.pill-reject { background:#fee2e2; color:#991b1b; }
.pill-cond { background:#fef3c7; color:#92400e; }
.pill-warn { background:#fee2e2; color:#991b1b; }
.empty { color:#94a3b8; font-style:italic; padding:40px 20px; text-align:center; background:white; border-radius:10px; }
.bar-item { display:flex; align-items:center; gap:10px; padding:6px 0; font-size:13px; }
.bar-item .name { flex:1; font-family:'SF Mono',Menlo,Consolas,monospace; font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.bar-item .bar-outer { flex:2; background:#e2e8f0; height:8px; border-radius:4px; overflow:hidden; }
.bar-item .bar-inner { background:#3b82f6; height:100%; }
.bar-item .count { width:40px; text-align:right; color:#64748b; font-size:12px; font-variant-numeric:tabular-nums; }
.mono { font-family:'SF Mono',Menlo,Consolas,monospace; font-size:12px; color:#475569; }
.refresh-hint { margin-top:16px; padding:12px; background:#1e293b; border-radius:6px; font-size:11px; color:#94a3b8; line-height:1.5; }
.refresh-hint code { color:#a5b4fc; background:transparent; font-size:11px; }
ul.zero-list { list-style:none; padding:0; margin:0; max-height:400px; overflow-y:auto; }
ul.zero-list li { padding:6px 0; border-bottom:1px solid #f1f5f9; }
</style>
</head>
<body>
<div class="app">
  <div class="sidebar">
    <h1>Harness Dashboard</h1>
    <div class="sub">生成于 __GENERATED_AT__</div>
    <ul id="project-list" class="project-list"></ul>
    <div class="refresh-hint">刷新数据：重新运行<br><code>/dashboard</code></div>
  </div>
  <div class="main">
    <div id="project-view"></div>
  </div>
</div>
<script>
const DATA = __DATA__;
let activeProject = null;
let activeTab = 'metrics';
let chartInstance = null;

function healthClass(val, good, warn) {
  if (val === null || val === undefined) return 'muted';
  if (val >= good) return 'good';
  if (val >= warn) return 'warn';
  return 'bad';
}
function inverseHealthClass(val, badThresh, warnThresh) {
  if (val === null || val === undefined) return 'muted';
  if (val <= warnThresh) return 'good';
  if (val <= badThresh) return 'warn';
  return 'bad';
}
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function renderProjectList() {
  const list = document.getElementById('project-list');
  list.innerHTML = '';
  DATA.projects.forEach(proj => {
    const li = document.createElement('li');
    if (proj === activeProject) li.className = 'active';
    const count = proj.data && proj.data.metrics ? proj.data.metrics.impl_count_30d : null;
    li.innerHTML = `<span>${esc(proj.name)}</span><span class="badge">${count !== null && count !== undefined ? count : '—'}</span>`;
    li.onclick = () => selectProject(proj);
    list.appendChild(li);
  });
}

function selectProject(proj) {
  activeProject = proj;
  activeTab = 'metrics';
  renderProjectList();
  renderProject();
}

function switchTab(tab) {
  activeTab = tab;
  renderProject();
}

function renderProject() {
  const proj = activeProject;
  const view = document.getElementById('project-view');
  if (!proj) { view.innerHTML = '<div class="empty">从左侧选择一个项目</div>'; return; }
  if (proj.data && proj.data.error) {
    view.innerHTML = `<div class="header"><h2>${esc(proj.name)}</h2></div><div class="card"><div class="bad">⚠️ ${esc(proj.data.error)}</div></div>`;
    return;
  }
  view.innerHTML = `
    <div class="header">
      <div>
        <h2>${esc(proj.name)}</h2>
        <div class="path">${esc(proj.path)}</div>
      </div>
      <div class="mono muted">${esc(proj.type || '')}</div>
    </div>
    <div class="tabs">
      <button class="tab ${activeTab==='metrics'?'active':''}" onclick="switchTab('metrics')">指标</button>
      <button class="tab ${activeTab==='knowledge'?'active':''}" onclick="switchTab('knowledge')">Knowledge</button>
      <button class="tab ${activeTab==='adversarial'?'active':''}" onclick="switchTab('adversarial')">对抗评估</button>
      <button class="tab ${activeTab==='timeline'?'active':''}" onclick="switchTab('timeline')">最近 impl</button>
      <button class="tab ${activeTab==='feedback'?'active':''}" onclick="switchTab('feedback')">命令反馈${feedbackBadge(proj)}</button>
    </div>
    <div id="panel" class="tab-panel active">${renderPanel(proj)}</div>
  `;
  if (activeTab === 'metrics') renderTrendChart(proj);
}

function renderPanel(proj) {
  switch (activeTab) {
    case 'metrics': return renderMetrics(proj);
    case 'knowledge': return renderKnowledge(proj);
    case 'adversarial': return renderAdversarial(proj);
    case 'timeline': return renderTimeline(proj);
    case 'feedback': return renderFeedback(proj);
  }
  return '';
}

function feedbackBadge(proj) {
  const list = (proj.data && proj.data.command_feedback) || [];
  const open = list.filter(f => f.status !== 'resolved').length;
  if (!open) return '';
  return ` <span class="pill pill-warn" style="margin-left:4px;">${open}</span>`;
}

function renderMetrics(proj) {
  const m = (proj.data && proj.data.metrics) || {};
  const p = (proj.data && proj.data.parallel_stats) || {};
  const fmt = (v, d=1) => (v === null || v === undefined) ? '—' : v.toFixed(d);
  const parallelSection = (p.parallel_tasks_30d || 0) > 0 ? `
    <div class="grid" style="margin-top:18px;">
      <div class="card"><h3>30 天并行任务数</h3>
        <div class="metric">${p.parallel_tasks_30d}<span class="unit"> / ${m.impl_count_30d ?? 0}</span></div>
        <div class="metric-sub">占比 ${fmt(p.parallel_tasks_share)}%；最大并发 ${p.max_parallel}</div>
      </div>
      <div class="card"><h3>并行波次</h3>
        <div class="metric">${p.wave_count_30d || 0}</div>
        <div class="metric-sub">成功 ${p.total_succeeded || 0} / 失败 ${p.total_failed || 0} / 合并冲突 ${p.total_merge_conflicts || 0}</div>
      </div>
      <div class="card"><h3>波次成功率</h3>
        <div class="metric ${healthClass(p.total_dispatched ? p.total_succeeded / p.total_dispatched * 100 : null, 80, 60)}">
          ${p.total_dispatched ? fmt(p.total_succeeded / p.total_dispatched * 100) : '—'}<span class="unit">%</span>
        </div>
        <div class="metric-sub">${p.total_dispatched || 0} 个任务被 dispatch</div>
      </div>
      <div class="card"><h3>合并冲突率</h3>
        <div class="metric ${inverseHealthClass(p.total_succeeded ? p.total_merge_conflicts / p.total_succeeded * 100 : null, 20, 10)}">
          ${p.total_succeeded ? fmt(p.total_merge_conflicts / p.total_succeeded * 100) : '—'}<span class="unit">%</span>
        </div>
        <div class="metric-sub">健康阈值 &lt;10%</div>
      </div>
    </div>
    ${p.recent_waves && p.recent_waves.length ? `
    <div class="card" style="margin-top:14px;padding:0;">
      <div style="padding:20px 20px 8px;"><h3 style="margin:0;">近期并行波次（${p.recent_waves.length}）</h3>
      <div class="metric-sub">每行一波；一次 /run-tasks --parallel N 通常包含多波</div></div>
      <table><thead><tr><th>时间</th><th>sprint</th><th>角色</th><th>wave</th><th>dispatch</th><th>成功</th><th>失败</th><th>冲突</th><th>耗时(min)</th></tr></thead>
      <tbody>${p.recent_waves.map(w => `<tr>
        <td class="mono">${esc((w.time || '').slice(0,16).replace('T',' '))}</td>
        <td class="mono">${esc(w.sprint || '—')}</td>
        <td>${esc(w.role || '—')}</td>
        <td class="mono">${esc(String(w.wave || '?'))} / ${esc(String(w.total_waves || '?'))}</td>
        <td>${w.dispatched || 0}</td>
        <td class="good">${w.succeeded || 0}</td>
        <td class="${(w.failed||0)>0?'bad':'muted'}">${w.failed || 0}</td>
        <td class="${(w.merge_conflicts||0)>0?'warn':'muted'}">${w.merge_conflicts || 0}</td>
        <td>${w.duration_minutes ?? '—'}</td>
      </tr>`).join('')}</tbody></table>
    </div>` : ''}
  ` : '';
  return `
    <div class="grid">
      <div class="card"><h3>30 天 impl 总数</h3><div class="metric">${m.impl_count_30d ?? 0}</div><div class="metric-sub">含 /impl 和 /run-tasks 子任务</div></div>
      <div class="card"><h3>首次通过率</h3><div class="metric ${healthClass(m.first_pass_rate, 60, 40)}">${fmt(m.first_pass_rate)}<span class="unit">%</span></div><div class="metric-sub">健康阈值 &gt;60%</div></div>
      <div class="card"><h3>平均自愈轮次</h3><div class="metric ${inverseHealthClass(m.avg_heal_cycles, 2, 1.2)}">${fmt(m.avg_heal_cycles, 2)}</div><div class="metric-sub">健康阈值 &lt;1.2</div></div>
      <div class="card"><h3>人工介入率</h3><div class="metric ${inverseHealthClass(m.human_intervention_rate, 25, 15)}">${fmt(m.human_intervention_rate)}<span class="unit">%</span></div><div class="metric-sub">健康阈值 &lt;15%</div></div>
    </div>
    <div class="chart-card"><h3>14 天首次通过率趋势</h3><div style="height:220px;"><canvas id="trend-chart"></canvas></div></div>
    ${parallelSection}
  `;
}

function renderTrendChart(proj) {
  if (chartInstance) { chartInstance.destroy(); chartInstance = null; }
  const trend = (proj.data && proj.data.trend) || [];
  const canvas = document.getElementById('trend-chart');
  if (!canvas) return;
  chartInstance = new Chart(canvas.getContext('2d'), {
    type: 'line',
    data: {
      labels: trend.map(d => d.date.slice(5)),
      datasets: [{
        label: '首次通过率 %',
        data: trend.map(d => d.rate),
        borderColor: '#3b82f6',
        backgroundColor: 'rgba(59,130,246,0.1)',
        tension: 0.3,
        spanGaps: true,
        pointRadius: 4,
        pointHoverRadius: 6,
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: { y: { beginAtZero: true, max: 100, ticks: { callback: v => v + '%' } } },
      plugins: { legend: { display: false }, tooltip: { callbacks: { label: ctx => `${ctx.parsed.y?.toFixed(1)}% (${trend[ctx.dataIndex].count} 次)` } } },
    }
  });
}

function renderKnowledge(proj) {
  const top = (proj.data && proj.data.knowledge_top) || [];
  const zero = (proj.data && proj.data.knowledge_zero_hit) || [];
  const total = (proj.data && proj.data.knowledge_total) || 0;
  const updates = (proj.data && proj.data.knowledge_updates) || [];
  const updatesCount = (proj.data && proj.data.knowledge_updates_count) || 0;
  const maxCount = top[0] ? top[0][1] : 1;
  const topHtml = top.length ? top.map(([file, count]) => `
    <div class="bar-item">
      <div class="name" title="${esc(file)}">${esc(file)}</div>
      <div class="bar-outer"><div class="bar-inner" style="width:${count/maxCount*100}%"></div></div>
      <div class="count">${count}</div>
    </div>`).join('') : '<div class="muted">暂无命中数据</div>';
  const zeroHtml = zero.length ? zero.map(f => `<li class="mono">${esc(f)}</li>`).join('') : '<li class="muted">全部被用过 👍</li>';
  const statusLabel = { A: '新增', M: '修改', D: '删除', S: '建议' };
  const statusCls = { A: 'pill-approve', M: 'pill-small', D: 'pill-reject', S: 'pill-cond' };
  const updatesHtml = updates.length ? updates.map(u => `
    <tr>
      <td class="mono">${esc((u.last_updated || '').slice(0,16).replace('T',' '))}</td>
      <td><span class="pill ${statusCls[u.status] || 'pill-small'}">${esc(statusLabel[u.status] || u.status)}</span></td>
      <td class="mono" title="${esc(u.file)}">${esc(u.file)}</td>
      <td>${esc(u.developer || '—')}</td>
      <td>${u.commits ? esc(String(u.commits)) : '—'}</td>
      <td class="muted">${esc(u.reason || '')}</td>
    </tr>`).join('') : '<tr><td colspan="6" class="muted" style="text-align:center;padding:20px;">近 30 天未见 knowledge/ 变更</td></tr>';
  return `
    <div class="grid" style="grid-template-columns:1fr 1fr;">
      <div class="card"><h3>30 天命中 Top ${Math.min(top.length, 15)}</h3>${topHtml}</div>
      <div class="card"><h3>30 天零命中（${zero.length} / ${total}）</h3><ul class="zero-list">${zeroHtml}</ul></div>
    </div>
    <div class="card" style="margin-top:14px;padding:0;">
      <div style="padding:20px 20px 8px;"><h3 style="margin:0;">30 天 Knowledge 更新（${updatesCount}）</h3>
      <div class="metric-sub">来源：git log knowledge/ + impl 事件建议</div></div>
      <table><thead><tr><th>时间</th><th>类型</th><th>文件</th><th>开发者</th><th>提交数</th><th>备注</th></tr></thead>
      <tbody>${updatesHtml}</tbody></table>
    </div>
  `;
}

function renderFeedback(proj) {
  const list = (proj.data && proj.data.command_feedback) || [];
  const bySev = (proj.data && proj.data.command_feedback_by_severity) || {};
  const byCmd = (proj.data && proj.data.command_feedback_by_cmd) || {};
  if (!list.length) {
    return '<div class="empty">暂无命令反馈。开发中踩到命令本身的坑时，跑 /command-feedback &lt;命令名&gt; "&lt;描述&gt;"，反馈会出现在这里。</div>';
  }
  const sevOrder = ['blocker','painful','minor','nice-to-have'];
  const sevCls = { blocker:'pill-reject', painful:'pill-cond', minor:'pill-small', 'nice-to-have':'pill-approve' };
  const statCards = sevOrder.map(sev => {
    const n = bySev[sev] || 0;
    return `<div class="card"><h3>${sev}</h3><div class="metric ${n?(sev==='blocker'?'bad':sev==='painful'?'warn':'muted'):'muted'}">${n}</div></div>`;
  }).join('');
  const byCmdEntries = Object.entries(byCmd).sort((a,b) => b[1]-a[1]);
  const cmdList = byCmdEntries.length ? byCmdEntries.map(([c,n]) => `
    <div class="bar-item">
      <div class="name mono">/${esc(c)}</div>
      <div class="bar-outer"><div class="bar-inner" style="width:${Math.min(n/5*100,100)}%"></div></div>
      <div class="count">${n}</div>
    </div>`).join('') : '<div class="muted">无</div>';
  const rows = list.map(f => `
    <tr>
      <td class="mono">${esc((f.created_at || '').slice(0,16).replace('T',' '))}</td>
      <td class="mono">/${esc(f.command)}</td>
      <td><span class="pill ${sevCls[f.severity] || 'pill-small'}">${esc(f.severity || '—')}</span></td>
      <td>${esc(f.developer || '—')}</td>
      <td>${esc(f.title || '')}</td>
      <td class="mono muted">${esc(f.file)}</td>
    </tr>`).join('');
  return `
    <div class="grid">${statCards}</div>
    <div class="grid" style="grid-template-columns:1fr 2fr;">
      <div class="card"><h3>按命令分布</h3>${cmdList}</div>
      <div class="card" style="padding:0;">
        <div style="padding:20px 20px 8px;"><h3 style="margin:0;">反馈详情（${list.length}）</h3>
        <div class="metric-sub">跑 <code class="mono">/command-feedback --collect</code> 汇总到 <code class="mono">~/.claude/command-feedback-inbox/</code></div></div>
        <table><thead><tr><th>时间</th><th>命令</th><th>严重性</th><th>开发者</th><th>标题</th><th>文件</th></tr></thead>
        <tbody>${rows}</tbody></table>
      </div>
    </div>
  `;
}

function renderAdversarial(proj) {
  const list = (proj.data && proj.data.adversarial) || [];
  const oracleReviews = (proj.data && proj.data.oracle_reviews) || [];
  const oracleStats = (proj.data && proj.data.oracle_stats) || {};
  if (!list.length) return '<div class="empty">暂无对抗评估记录。PR/Sprint 合并前跑 /adversarial-review 后数据会出现在这里。</div>';

  // Oracle 模式汇总（若有）
  let oracleSection = '';
  if (oracleReviews.length > 0) {
    const verdictPill = v => {
      const s = (v || '').toLowerCase();
      if (s.startsWith('approve-with') || s === 'approve_with_fix') return 'pill-cond';
      if (s.startsWith('approve')) return 'pill-approve';
      if (s.startsWith('reject')) return 'pill-reject';
      return 'pill-small';
    };
    const orRows = oracleReviews.map(r => {
      const override = r.override_by ? `<span class="pill pill-cond" title="${esc(r.override_reason||'')}">人工 override by ${esc(r.override_by)}</span>` : '';
      const disBadge = r.disagreement ? '<span class="pill pill-reject" title="A/B 分差 > 15 或维度分差 > 10">分歧</span>' : '';
      const modeBadge = r.mode === 'serial' ? '<span class="pill pill-cond">serial</span>' : '<span class="pill pill-small">3-session</span>';
      return `<tr>
        <td class="mono">${esc((r.time || '').slice(0,16).replace('T',' '))}</td>
        <td class="mono">${esc(r.sprint || '—')}</td>
        <td>${r.a_score ?? '—'} / ${r.b_score ?? '—'}<span class="muted"> (A/B)</span></td>
        <td><span class="pill ${verdictPill(r.a_verdict)}">${esc(r.a_verdict || '?')}</span> <span class="pill ${verdictPill(r.b_verdict)}">${esc(r.b_verdict || '?')}</span></td>
        <td><span class="pill ${verdictPill(r.final_verdict)}">${esc(r.final_verdict || '?')}</span> ${disBadge} ${override}</td>
        <td>${r.must_fix_union ?? 0}</td>
        <td>${modeBadge}</td>
      </tr>`;
    }).join('');
    oracleSection = `
      <div class="grid">
        <div class="card"><h3>Oracle 评估数</h3><div class="metric">${oracleStats.review_count || 0}</div><div class="metric-sub">每次 3 条 adversarial/ 记录（A/B/aggregate）</div></div>
        <div class="card"><h3>分歧率</h3><div class="metric ${inverseHealthClass(oracleStats.review_count ? oracleStats.disagreement_count / oracleStats.review_count * 100 : null, 30, 15)}">${oracleStats.review_count ? ((oracleStats.disagreement_count/oracleStats.review_count)*100).toFixed(1) : '—'}<span class="unit">%</span></div><div class="metric-sub">A/B 分差 &gt; 15</div></div>
        <div class="card"><h3>Reject 率</h3><div class="metric ${inverseHealthClass(oracleStats.review_count ? oracleStats.reject_count / oracleStats.review_count * 100 : null, 40, 20)}">${oracleStats.review_count ? ((oracleStats.reject_count/oracleStats.review_count)*100).toFixed(1) : '—'}<span class="unit">%</span></div><div class="metric-sub">strict-AND 触发</div></div>
        <div class="card"><h3>人工 Override</h3><div class="metric ${(oracleStats.override_count||0)>0?'warn':'muted'}">${oracleStats.override_count || 0}</div><div class="metric-sub">--arbiter-approve 记录</div></div>
      </div>
      <div class="card" style="margin-top:14px;padding:0;">
        <div style="padding:20px 20px 8px;"><h3 style="margin:0;">Oracle Reviews（${oracleReviews.length}）</h3>
        <div class="metric-sub">strict-AND 仲裁；分歧或 override 用徽章高亮</div></div>
        <table><thead><tr><th>时间</th><th>sprint</th><th>分数 (A/B)</th><th>A/B 判定</th><th>最终</th><th>Must-Fix 并集</th><th>模式</th></tr></thead>
        <tbody>${orRows}</tbody></table>
      </div>
    `;
  }

  // 单 Evaluator（不含 Oracle 子事件）
  const soloList = list.filter(a => !a.oracle);
  let soloSection = '';
  if (soloList.length > 0) {
    const rows = soloList.map(a => {
      const rec = (a.recommendation || '').toLowerCase();
      const cls = rec.startsWith('approve-with') ? 'pill-cond' : rec.startsWith('approve') ? 'pill-approve' : rec.startsWith('reject') ? 'pill-reject' : 'pill-small';
      const reasons = (a.reject_reasons || []).join('; ') || '—';
      return `<tr>
        <td class="mono">${esc((a.time || '').slice(0,16).replace('T',' '))}</td>
        <td class="mono">${esc(a.branch)}</td>
        <td>${a.score !== null && a.score !== undefined ? a.score : '—'}</td>
        <td>${a.must_fix || 0}</td>
        <td><span class="pill ${cls}">${esc(rec || 'unknown')}</span></td>
        <td class="muted">${esc(reasons)}</td>
      </tr>`;
    }).join('');
    soloSection = `
      <div class="card" style="padding:0;${oracleReviews.length ? 'margin-top:14px;' : ''}">
        <div style="padding:20px 20px 8px;"><h3 style="margin:0;">单 Evaluator（${soloList.length}）</h3></div>
        <table><thead><tr><th>时间</th><th>分支</th><th>总分</th><th>Must-Fix</th><th>结论</th><th>原因</th></tr></thead><tbody>${rows}</tbody></table>
      </div>`;
  }

  return oracleSection + soloSection;
}

function renderTimeline(proj) {
  const list = (proj.data && proj.data.timeline) || [];
  if (!list.length) return '<div class="empty">最近 30 天暂无 impl 事件。</div>';
  const rows = list.map(e => {
    const sizeCls = e.task_size === 'large' ? 'pill-large' : 'pill-small';
    const warn = e.human_intervention ? '<span class="pill pill-warn">介入</span>' : '';
    const redLines = (e.red_lines_triggered || []).length ? `<span class="pill pill-warn">红线×${e.red_lines_triggered.length}</span>` : '';
    return `<tr>
      <td class="mono">${esc((e.time || '').slice(0,16).replace('T',' '))}</td>
      <td>${esc(e.developer || '—')}</td>
      <td>${esc(e.task_desc || '')}</td>
      <td>${e.task_size ? `<span class="pill ${sizeCls}">${esc(e.task_size)}</span>` : '—'}</td>
      <td>${esc(e.role || '—')}</td>
      <td>${e.heal_cycles ?? 0}</td>
      <td>${e.duration_minutes ?? '—'}</td>
      <td class="mono">${esc((e.commit_hash || '').slice(0,8) || '—')}</td>
      <td>${warn}${redLines}</td>
    </tr>`;
  }).join('');
  return `<div class="card" style="padding:0;"><table><thead><tr><th>时间</th><th>开发者</th><th>任务</th><th>大小</th><th>角色</th><th>自愈</th><th>耗时</th><th>commit</th><th>标记</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

// 初始化
renderProjectList();
if (DATA.projects.length > 0) selectProject(DATA.projects[0]);
else document.getElementById('project-view').innerHTML = '<div class="empty">注册表里还没有项目。在项目根目录跑一次 setup.sh 或 upgrade.sh 会自动注册。</div>';
</script>
</body>
</html>
"""


def render_html(payload):
    data_json = json.dumps(payload, ensure_ascii=False, default=str)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return HTML_TEMPLATE.replace("__DATA__", data_json).replace("__GENERATED_AT__", now)


# ---------------- 入口 ----------------

def main():
    ap = argparse.ArgumentParser(description="生成 Harness Dashboard HTML 看板")
    ap.add_argument("--config", default=str(CONFIG), help="项目注册表 yaml")
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT), help="HTML 输出路径")
    ap.add_argument("--open", action="store_true", help="生成后用默认浏览器打开")
    args = ap.parse_args()

    config = parse_yaml_simple(Path(args.config))
    projects = config.get("projects", [])

    payload = {
        "generated_at": datetime.now().isoformat(sep=" ", timespec="seconds"),
        "projects": [],
    }
    for p in projects:
        path = os.path.expanduser(p.get("path", ""))
        payload["projects"].append({
            "name": p.get("name", "unknown"),
            "path": path,
            "type": p.get("type", ""),
            "data": aggregate_project({"path": path, **p}),
        })

    output = Path(os.path.expanduser(args.output))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_html(payload), encoding="utf-8")

    print(f"✅ Dashboard 已生成：{output}")
    print(f"   项目数：{len(projects)}")
    for p in payload["projects"]:
        err = p["data"].get("error") if isinstance(p["data"], dict) else None
        status = f"⚠️ {err}" if err else f"impl(30d)={p['data']['metrics']['impl_count_30d']}"
        print(f"   · {p['name']}：{status}")

    if args.open:
        webbrowser.open(f"file://{output.absolute()}")


if __name__ == "__main__":
    main()
