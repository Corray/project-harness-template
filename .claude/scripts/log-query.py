#!/usr/bin/env python3
"""
log-query.py — 远程日志查询（paramiko + 密码 env var 鉴权）

设计参考：项目里 login_consum.py 的 paramiko 用法（同 user/auth/host_policy 模式）。

核心特性：
  · username + password 鉴权，密码从 env var 读，不进 logs.yaml
  · paramiko.SSHClient + AutoAddPolicy（首次连自动接受 host key）
  · look_for_keys=False, allow_agent=False（不混用 ssh-agent / 私钥）
  · 只构造 read-only 命令（tail / grep / cat / zcat / ls）
  · path / pattern 字符校验防注入

用法：
  python3 .claude/scripts/log-query.py --list                       列已配 target
  python3 .claude/scripts/log-query.py --add                        交互式新增
  python3 .claude/scripts/log-query.py --remove NAME                删除
  python3 .claude/scripts/log-query.py --files NAME                 列 target 上的日志文件
  python3 .claude/scripts/log-query.py --target NAME [选项]          查询日志

查询选项：
  --tail N          最后 N 行（默认 200）
  --grep PATTERN    过滤模式（可重复，多个 AND）
  --grep-v PATTERN  排除模式（可重复，多个 AND）
  --context N       匹配行的前后 N 行上下文（grep -C N）
  --paths P1 P2 ... 一次性覆盖 logs.yaml 里的 paths
  --raw             不带 grep，纯 tail

示例：
  python3 .claude/scripts/log-query.py --list
  python3 .claude/scripts/log-query.py --target prod-app --tail 500
  python3 .claude/scripts/log-query.py --target prod-app --grep "OutOfMemory" --context 10
  python3 .claude/scripts/log-query.py --target prod-app --grep "ERROR" --grep-v "expected"

依赖：paramiko, PyYAML
  pip install paramiko pyyaml --break-system-packages
"""

import argparse
import os
import re
import shlex
import sys

LOGS_YAML = ".claude/logs.yaml"

# ──── ANSI 颜色 ────
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
NC = "\033[0m"


def err(msg, code=2):
    print(f"{RED}错误：{msg}{NC}", file=sys.stderr)
    sys.exit(code)


def warn(msg):
    print(f"{YELLOW}{msg}{NC}", file=sys.stderr)


# ──── 依赖检测 ────
def _require_yaml():
    try:
        import yaml
        return yaml
    except ImportError:
        err("需要 PyYAML：pip install pyyaml --break-system-packages")


def _require_paramiko():
    try:
        import paramiko
        return paramiko
    except ImportError:
        err("需要 paramiko：pip install paramiko --break-system-packages")


# ──── YAML 读写 ────
def load_cfg():
    yaml = _require_yaml()
    if not os.path.exists(LOGS_YAML):
        return {"targets": {}}
    with open(LOGS_YAML) as f:
        cfg = yaml.safe_load(f) or {}
    cfg.setdefault("targets", {})
    return cfg


def save_cfg(cfg):
    yaml = _require_yaml()
    parent = os.path.dirname(LOGS_YAML)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    with open(LOGS_YAML, "w") as f:
        yaml.safe_dump(
            cfg, f, allow_unicode=True, sort_keys=False, default_flow_style=False
        )


# ──── 校验 ────
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
PATH_RE = re.compile(r"^[A-Za-z0-9_./\-*?+\[\]@~]+$")
PATTERN_BAD_TOKENS = [";", "&", "`", "$(", "\n", "\r"]


def check_paths(paths):
    for p in paths:
        if not PATH_RE.match(p):
            err(f"path 含非法字符：{p}")


def check_patterns(patterns):
    for p in patterns:
        for bad in PATTERN_BAD_TOKENS:
            if bad in p:
                err(f"pattern 含 shell metachar '{bad}'：{p}")


# ──── target 解析 ────
def resolve_target(name):
    cfg = load_cfg()
    targets = cfg["targets"]
    if name not in targets:
        msg = f"target '{name}' 不在 {LOGS_YAML}"
        if targets:
            msg += f"\n  可用 target: {', '.join(targets.keys())}"
        else:
            msg += "\n  （logs.yaml 是空的，先 --add）"
        err(msg)

    t = targets[name]
    host = t.get("host")
    user = t.get("user")
    pwd_env = t.get("password_env")

    if not host or not user:
        err(f"target '{name}' 缺 host 或 user 字段")
    if not pwd_env:
        err(f"target '{name}' 没配 password_env（密码所在 env var 名）")

    password = os.environ.get(pwd_env)
    if not password:
        err(
            f"环境变量 {pwd_env} 未设置或为空\n"
            f"  在 ~/.zshrc 加：export {pwd_env}=\"...\"\n"
            f"  然后 source ~/.zshrc 后再开新 shell"
        )

    return {
        "name": name,
        "host": host,
        "user": user,
        "port": int(t.get("port", 22)),
        "password": password,
        "paths": t.get("paths", []) or [],
        "default_grep_v": t.get("default_grep_v", []) or [],
    }


# ──── SSH 连接 ────
def ssh_connect(target, timeout=10.0):
    paramiko = _require_paramiko()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=target["host"],
            port=target["port"],
            username=target["user"],
            password=target["password"],
            timeout=timeout,
            look_for_keys=False,
            allow_agent=False,
        )
    except paramiko.AuthenticationException:
        err(
            f"鉴权失败：{target['user']}@{target['host']}:{target['port']}（密码错？）\n"
            f"  检查 env var ${target.get('_pwd_env_name','?')} 的值是否正确"
        )
    except paramiko.SSHException as e:
        err(f"SSH 错误：{e}")
    except OSError as e:
        err(f"连接 {target['host']}:{target['port']} 失败：{e}")
    except Exception as e:
        err(f"未预期错误：{type(e).__name__}: {e}")
    return client


def exec_remote_streaming(client, cmd, timeout=300):
    """在远端跑 cmd，流式打印 stdout，stderr 单独打到本地 stderr。"""
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    # stdout 流式
    while True:
        line = stdout.readline()
        if not line:
            break
        # paramiko 的 readline 在 Python 3 返回 str（已 decode）
        sys.stdout.write(line)
        sys.stdout.flush()
    # stderr 一次性
    err_text = stderr.read()
    if isinstance(err_text, bytes):
        err_text = err_text.decode("utf-8", errors="replace")
    if err_text and err_text.strip():
        sys.stderr.write(err_text)
    # 退出码不当错误处理：grep 无匹配会返回 1，属正常


# ──── 子命令 ────
def cmd_list():
    cfg = load_cfg()
    targets = cfg["targets"]
    if not targets:
        print("（logs.yaml 没有 targets，先用 --add 创建）")
        return
    print(f"{'名字':<22} {'用户@主机:端口':<32} {'路径数':<6} {'密码 env':<28}")
    print("-" * 92)
    for name, t in targets.items():
        host = t.get("host", "?")
        user = t.get("user", "?")
        port = t.get("port", 22)
        pwd_env = t.get("password_env", "")
        addr = f"{user}@{host}:{port}"
        n_paths = len(t.get("paths") or [])
        if not pwd_env:
            pwd_status = "(未配 password_env)"
        elif os.environ.get(pwd_env):
            pwd_status = f"✓ ${pwd_env}"
        else:
            pwd_status = f"⚠ ${pwd_env} 未设置"
        print(f"{name:<22} {addr:<32} {n_paths:<6} {pwd_status:<28}")


def cmd_add():
    cfg = load_cfg()

    print(f"\n{CYAN}═══════════════════════════════════════════════{NC}")
    print(f"{CYAN}  添加日志 target{NC}")
    print(f"{CYAN}═══════════════════════════════════════════════{NC}")

    while True:
        name = input("名字（如 prod-app / order-service）: ").strip()
        if not name:
            print("  名字不能为空")
            continue
        if not NAME_RE.match(name):
            print("  只能小写字母/数字/连字符，必须以字母数字开头")
            continue
        break

    host = input("服务器 IP 或 hostname: ").strip()
    if not host:
        err("host 不能为空")

    user = input("远端用户名（默认 dev）: ").strip() or "dev"

    port_s = input("SSH 端口（默认 22）: ").strip()
    try:
        port = int(port_s) if port_s else 22
    except ValueError:
        err(f"端口必须是数字：{port_s}")

    default_pwd_env = re.sub(r"[^A-Z0-9]", "_", name.upper()) + "_SSH_PWD"
    pwd_env = (
        input(f"密码环境变量名（默认 {default_pwd_env}）: ").strip()
        or default_pwd_env
    )
    if not re.match(r"^[A-Z_][A-Z0-9_]*$", pwd_env):
        err(f"env var 名只能大写字母 / 数字 / 下划线：{pwd_env}")

    print("\n日志文件路径（一行一个，支持 glob，回车空行结束）")
    print("  例：/app/webapps/logs/chatlabs-marketing-platform-single.*.log")
    print("  例：/var/log/app/error.log")
    paths = []
    while True:
        p = input("  > ").strip()
        if not p:
            break
        paths.append(p)
    if not paths:
        err("至少要 1 个路径")

    print("\n默认排除模式 grep -v（可选，一行一个，回车结束）")
    grep_v = []
    while True:
        p = input("  > ").strip()
        if not p:
            break
        grep_v.append(p)

    entry = {
        "host": host,
        "user": user,
        "password_env": pwd_env,
        "paths": paths,
    }
    if port != 22:
        entry["port"] = port
    if grep_v:
        entry["default_grep_v"] = grep_v

    existed = name in cfg["targets"]
    cfg["targets"][name] = entry
    save_cfg(cfg)

    print(f"\n{GREEN}{'更新' if existed else '新增'} target: {name}{NC}")
    print(f"\n{YELLOW}⚠ 在 ~/.zshrc 添加：{NC}")
    print(f'  export {pwd_env}="实际密码"')
    print(f"然后 {CYAN}source ~/.zshrc{NC} 后再开新 shell。")
    print(
        f"\n下一步：python3 .claude/scripts/log-query.py --target {name} --tail 100"
    )


def cmd_remove(name):
    cfg = load_cfg()
    if name not in cfg["targets"]:
        print(f"（{name} 不在 logs.yaml 里，跳过）")
        return
    del cfg["targets"][name]
    save_cfg(cfg)
    print(f"已删除 target: {name}")


def cmd_files(name):
    target = resolve_target(name)
    paths = target["paths"]
    if not paths:
        err("该 target 没有配置 paths")
    check_paths(paths)
    quoted = " ".join(shlex.quote(p) for p in paths)
    cmd = f"ls -la {quoted} 2>/dev/null || true"
    print(f"{BLUE}>>> [{target['user']}@{target['host']}:{target['port']}] {cmd}{NC}")
    client = ssh_connect(target)
    try:
        exec_remote_streaming(client, cmd, timeout=30)
    finally:
        client.close()


def cmd_query(args):
    target = resolve_target(args.target)
    paths = list(args.paths) if args.paths else list(target["paths"])
    if not paths:
        err("没有 paths（target 配置为空且未传 --paths）")
    check_paths(paths)

    greps = list(args.grep or [])
    grep_vs = list(target["default_grep_v"]) + list(args.grep_v or [])
    check_patterns(greps + grep_vs)

    tail_n = args.tail if args.tail is not None else 200
    if tail_n < 1 or tail_n > 1_000_000:
        err(f"--tail 必须在 1..1000000 范围：{tail_n}")

    if args.context is not None and (args.context < 0 or args.context > 1000):
        err(f"--context 必须在 0..1000 范围：{args.context}")

    parts = []
    quoted_paths = " ".join(shlex.quote(p) for p in paths)
    parts.append(f"tail -n {tail_n} {quoted_paths} 2>/dev/null")

    for pat in grep_vs:
        parts.append(f"grep -v -E {shlex.quote(pat)}")

    ctx = f"-C {args.context} " if args.context else ""
    for pat in greps:
        parts.append(f"grep {ctx}-E {shlex.quote(pat)}")

    cmd = parts[0] if args.raw else " | ".join(parts)

    print(f"{BLUE}>>> [{target['user']}@{target['host']}:{target['port']}] {cmd}{NC}")
    print("─" * 60)

    client = ssh_connect(target)
    try:
        exec_remote_streaming(client, cmd, timeout=300)
    finally:
        client.close()


# ──── 主入口 ────
def main():
    p = argparse.ArgumentParser(
        prog="log-query.py",
        description="远程日志查询（paramiko + 密码 env var 鉴权）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python3 .claude/scripts/log-query.py --list\n"
            "  python3 .claude/scripts/log-query.py --add\n"
            "  python3 .claude/scripts/log-query.py --target prod-app --tail 500\n"
            "  python3 .claude/scripts/log-query.py --target prod-app --grep \"OutOfMemory\" --context 10\n"
        ),
    )
    p.add_argument("--list", action="store_true", help="列已配 target")
    p.add_argument("--add", action="store_true", help="交互式新增 target")
    p.add_argument("--remove", metavar="NAME", help="删除指定 target")
    p.add_argument(
        "--files", metavar="NAME", help="列该 target 的日志文件，不取内容"
    )
    p.add_argument("--target", metavar="NAME", help="查询模式：指定 target 名")
    p.add_argument(
        "--tail", type=int, metavar="N", help="最后 N 行（默认 200）"
    )
    p.add_argument(
        "--grep",
        action="append",
        metavar="PATTERN",
        help="过滤模式（可重复，多个 AND）",
    )
    p.add_argument(
        "--grep-v",
        dest="grep_v",
        action="append",
        metavar="PATTERN",
        help="排除模式（可重复，多个 AND）",
    )
    p.add_argument(
        "--context",
        "-C",
        type=int,
        metavar="N",
        help="grep -C N 上下文",
    )
    p.add_argument(
        "--paths",
        nargs="+",
        metavar="PATH",
        help="一次性覆盖 logs.yaml 里的 paths",
    )
    p.add_argument(
        "--raw", action="store_true", help="不带 grep，纯 tail 输出"
    )

    args = p.parse_args()

    # 模式分发（按优先级）
    if args.list:
        cmd_list()
    elif args.add:
        cmd_add()
    elif args.remove:
        cmd_remove(args.remove)
    elif args.files:
        cmd_files(args.files)
    elif args.target:
        cmd_query(args)
    else:
        p.print_help()
        sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n（已中断）", file=sys.stderr)
        sys.exit(130)
