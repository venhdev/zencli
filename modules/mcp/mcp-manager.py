#!/usr/bin/env python3
"""
ZenCLI MCP Manager
Authoritative multi-client Model Context Protocol orchestrator for AI Agent Tools.
Supported clients: opencode, agy, claude, codex, cursor.
SSOT Reference: https://github.com/venhdev/zenforge/blob/main/MCP.md
"""

import argparse
from datetime import datetime
import json
import os
import re
import shutil
import sys

try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        tomllib = None


def require_tomllib():
    if tomllib is None:
        print("❌ Error: Python 3.11+ (or package 'tomli') is required to parse Codex TOML configurations.", file=sys.stderr)
        sys.exit(1)

CLIENT_SPECS = {
    "opencode": {
        "name": "OpenCode",
        "type": "json",
        "default_path": lambda: os.path.join(
            os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
            "opencode",
            "opencode.json",
        ),
    },
    "agy": {
        "name": "Antigravity / Gemini CLI",
        "type": "json",
        "default_path": lambda: os.path.expanduser("~/.gemini/config/mcp_config.json"),
    },
    "claude": {
        "name": "Claude Code",
        "type": "json",
        "default_path": lambda: os.path.expanduser("~/.claude.json"),
    },
    "codex": {
        "name": "Codex CLI",
        "type": "toml",
        "default_path": lambda: os.path.expanduser("~/.codex/config.toml"),
    },
    "cursor": {
        "name": "Cursor IDE",
        "type": "json",
        "default_path": lambda: os.path.expanduser("~/.cursor/mcp.json"),
    },
}

ALL_CLIENTS = ["opencode", "agy", "claude", "codex", "cursor"]


def resolve_binary(override=None):
    if override:
        clean = os.path.abspath(os.path.expanduser(override))
        if os.path.exists(clean) and os.access(clean, os.X_OK):
            return clean
        if os.path.exists(clean):
            return clean
        return clean

    # 1. Check PATH
    which_zenf = shutil.which("zenf")
    if which_zenf:
        return os.path.abspath(which_zenf)

    # 2. Check canonical user & local locations
    candidates = [
        os.path.expanduser("~/.local/bin/zenf"),
        "/usr/local/bin/zenf",
        os.path.expanduser("~/src/owner/zenforge/apps/daemon/bin/zenf"),
        os.path.expanduser("~/src/owner/zenforge/bin/zenf"),
    ]
    for cand in candidates:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return os.path.abspath(cand)

    return "zenf"


PRESET_CATALOG = {
    "zenforge": {
        "name": "ZenForge",
        "description": "ZenForge MCP tracking plane & task state machine",
        "package": "native: zenf",
        "default_server_name": "zenf",
        "builder": lambda **kw: {
            "command": resolve_binary(kw.get("binary")),
            "args": ["mcp", "stdio", "--workspace", kw.get("workspace") or "default"],
            "env": kw.get("env") or {},
        },
    },
    "sqlite": {
        "name": "SQLite",
        "description": "Official SQLite Model Context Protocol server (uvx)",
        "package": "PyPI: mcp-server-sqlite (uvx)",
        "default_server_name": "sqlite",
        "builder": lambda **kw: {
            "command": "uvx",
            "args": ["mcp-server-sqlite", "--db-path", kw.get("db") or os.path.expanduser("~/.local/share/mcp/default.db")],
            "env": kw.get("env") or {},
        },
    },
    "github": {
        "name": "GitHub",
        "description": "Official GitHub Model Context Protocol server (npx)",
        "package": "npm: @modelcontextprotocol/server-github (npx)",
        "default_server_name": "github",
        "builder": lambda **kw: {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-github"],
            "env": {
                **({"GITHUB_PERSONAL_ACCESS_TOKEN": kw.get("token")} if kw.get("token") else {}),
                **(kw.get("env") or {}),
            },
        },
    },
    "fetch": {
        "name": "Fetch",
        "description": "Web content fetcher Model Context Protocol server (uvx)",
        "package": "PyPI: mcp-server-fetch (uvx)",
        "default_server_name": "fetch",
        "builder": lambda **kw: {
            "command": "uvx",
            "args": ["mcp-server-fetch"],
            "env": kw.get("env") or {},
        },
    },
    "filesystem": {
        "name": "Filesystem",
        "description": "Local filesystem access Model Context Protocol server (npx)",
        "package": "npm: @modelcontextprotocol/server-filesystem (npx)",
        "default_server_name": "filesystem",
        "builder": lambda **kw: {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", kw.get("path") or os.path.expanduser("~")],
            "env": kw.get("env") or {},
        },
    },
    "postgres": {
        "name": "Postgres",
        "description": "PostgreSQL database Model Context Protocol server (npx)",
        "package": "npm: @modelcontextprotocol/server-postgres (npx)",
        "default_server_name": "postgres",
        "builder": lambda **kw: {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-postgres", kw.get("conn") or "postgresql://localhost/mydb"],
            "env": kw.get("env") or {},
        },
    },
}


def get_config_path(client, override=None):
    if override:
        return os.path.abspath(os.path.expanduser(override))
    if client in CLIENT_SPECS:
        return CLIENT_SPECS[client]["default_path"]()
    raise ValueError(f"Unknown client: {client}")


def read_json_config(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if not content.strip():
        return {}
    return json.loads(content)


def make_backup(path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        ts = datetime.now().strftime("%y%m%d%H%M")
        backup_path = f"{path}.{ts}.bak"
        shutil.copy2(path, backup_path)
        return backup_path
    return None


def write_json_config(path, data, dry_run=False):
    content = json.dumps(data, indent=2) + "\n"
    if dry_run:
        return content, None

    os.makedirs(os.path.dirname(path), exist_ok=True)
    backup_path = make_backup(path)

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return content, backup_path


def update_toml_server(content, server_name, bin_path, args, env=None, url=None, token=None, remove=False):
    require_tomllib()
    pattern = rf'(?ms)^\[mcp_servers\.(?:\"{re.escape(server_name)}\"|{re.escape(server_name)})\]\s*.*?(?=(?:^\[|\Z))'
    if remove:
        new_content = re.sub(pattern, "", content).rstrip() + "\n"
        if new_content.strip():
            tomllib.loads(new_content)
        return new_content

    header_key = server_name if re.match(r'^[A-Za-z0-9_-]+$', server_name) else f'"{server_name}"'
    if url:
        lines = [f"[mcp_servers.{header_key}]", f"url = {json.dumps(url)}"]
        if token:
            lines.append(f"bearer_token_env_var = {json.dumps(token)}")
        lines.append("")
        section_str = "\n".join(lines)
    else:
        args_formatted = ", ".join(json.dumps(str(a)) for a in args)
        lines = [
            f"[mcp_servers.{header_key}]",
            f"command = {json.dumps(str(bin_path))}",
            f"args = [{args_formatted}]",
        ]
        if env and isinstance(env, dict) and len(env) > 0:
            env_items = ", ".join(f'{k} = {json.dumps(str(v))}' for k, v in env.items())
            lines.append(f"env = {{ {env_items} }}")
        lines.append("")
        lines.append("")
        section_str = "\n".join(lines)

    if re.search(pattern, content):
        new_content = re.sub(pattern, lambda _: section_str, content)
    else:
        new_content = content.rstrip()
        if new_content:
            new_content += "\n\n" + section_str
        else:
            new_content = section_str

    tomllib.loads(new_content)
    return new_content


def inspect_single_server(client, s_name, s_entry):
    if not isinstance(s_entry, dict):
        return None

    info = {
        "name": s_name,
        "transport": "stdio",
        "binary_path": "",
        "binary_exists": False,
        "args": [],
        "env": s_entry.get("env", {}) if isinstance(s_entry.get("env"), dict) else {},
        "workspace": "",
        "url": "",
        "status": "CONFIGURED",
    }

    if "serverUrl" in s_entry:
        info["transport"] = "http"
        info["url"] = s_entry["serverUrl"]
    elif "url" in s_entry:
        info["transport"] = "http"
        info["url"] = s_entry["url"]
    else:
        info["transport"] = "stdio"
        if client == "opencode":
            cmd = s_entry.get("command", [])
            if isinstance(cmd, list) and len(cmd) > 0:
                info["binary_path"] = str(cmd[0])
                info["args"] = [str(a) for a in cmd[1:]]
            elif isinstance(cmd, str):
                info["binary_path"] = cmd
                info["args"] = [str(a) for a in s_entry.get("args", [])] if isinstance(s_entry.get("args"), list) else []
        else:
            info["binary_path"] = str(s_entry.get("command", ""))
            info["args"] = [str(a) for a in s_entry.get("args", [])] if isinstance(s_entry.get("args"), list) else []

        for i, arg in enumerate(info["args"]):
            if arg == "--workspace" and i + 1 < len(info["args"]):
                info["workspace"] = info["args"][i + 1]

        bin_path = info["binary_path"]
        if bin_path and (os.path.exists(bin_path) or shutil.which(bin_path)):
            info["binary_exists"] = True
            info["status"] = "CONFIGURED"
        else:
            info["status"] = "BINARY_MISSING"

    return info


def check_client(client, config_override=None, server_name=None):
    cfg_path = get_config_path(client, config_override)
    res = {
        "client": client,
        "name": CLIENT_SPECS[client]["name"],
        "config_path": cfg_path,
        "file_exists": os.path.exists(cfg_path),
        "configured": False,
        "server_name": server_name or "-",
        "servers": {},
        "total_servers": 0,
        "binary_path": "",
        "binary_exists": False,
        "args": [],
        "env": {},
        "workspace": "",
        "transport": "",
        "url": "",
        "status": "NOT_CONFIGURED",
    }

    if not res["file_exists"]:
        res["status"] = "FILE_MISSING"
        return res

    try:
        raw_servers = {}
        if CLIENT_SPECS[client]["type"] == "json":
            data = read_json_config(cfg_path)
            if client == "opencode":
                mcp = data.get("mcp", {})
                if isinstance(mcp, dict):
                    if "servers" in mcp and isinstance(mcp["servers"], dict):
                        raw_servers = mcp["servers"]
                    else:
                        raw_servers = {k: v for k, v in mcp.items() if isinstance(v, dict) and k != "provider"}
            else:
                servers = data.get("mcpServers", {})
                if isinstance(servers, dict):
                    raw_servers = servers

        elif CLIENT_SPECS[client]["type"] == "toml":
            require_tomllib()
            with open(cfg_path, "rb") as f:
                data = tomllib.load(f)
            servers = data.get("mcp_servers", {})
            if isinstance(servers, dict):
                raw_servers = servers

        # Inspect all servers
        parsed_servers = {}
        for s_name, s_val in raw_servers.items():
            parsed = inspect_single_server(client, s_name, s_val)
            if parsed:
                parsed_servers[s_name] = parsed

        res["servers"] = parsed_servers
        res["total_servers"] = len(parsed_servers)

        if server_name:
            if server_name in parsed_servers:
                res["configured"] = True
                s = parsed_servers[server_name]
                res["server_name"] = s["name"]
                res["binary_path"] = s["binary_path"]
                res["binary_exists"] = s["binary_exists"]
                res["args"] = s["args"]
                res["env"] = s["env"]
                res["workspace"] = s["workspace"]
                res["transport"] = s["transport"]
                res["url"] = s["url"]
                res["status"] = s["status"]
            else:
                res["configured"] = False
                res["status"] = "NOT_CONFIGURED"
        else:
            if len(parsed_servers) == 0:
                res["configured"] = False
                res["status"] = "NOT_CONFIGURED"
            else:
                res["configured"] = True
                has_missing = any(s["status"] == "BINARY_MISSING" for s in parsed_servers.values())
                res["status"] = "BINARY_MISSING" if has_missing else "CONFIGURED"

                # Mirror primary server for single-server consumers
                primary_s = parsed_servers.get("zenf") or next(iter(parsed_servers.values()))
                res["server_name"] = primary_s["name"]
                res["binary_path"] = primary_s["binary_path"]
                res["binary_exists"] = primary_s["binary_exists"]
                res["args"] = primary_s["args"]
                res["env"] = primary_s["env"]
                res["workspace"] = primary_s["workspace"]
                res["transport"] = primary_s["transport"]
                res["url"] = primary_s["url"]

    except Exception as e:
        res["status"] = f"ERROR: {e}"

    return res


def setup_client(client, config_override=None, server_name="zenf", command=None, args=None, env=None,
                 workspace=None, url=None, token=None, force=False, dry_run=False):
    cfg_path = get_config_path(client, config_override)
    
    if command is None and not url:
        bin_path = resolve_binary()
        args = ["mcp", "stdio", "--workspace", workspace or "default"]
    else:
        bin_path = command or ""
        args = args or []
    
    env_map = env or {}

    existing = check_client(client, cfg_path, server_name=server_name)
    if existing["configured"] and not force:
        if url:
            if existing.get("url") == url:
                return {"action": "already_configured", "client": client, "path": cfg_path, "status": "ALREADY_CONFIGURED"}
        else:
            if (existing.get("binary_path") == bin_path and 
                existing.get("args") == args and 
                existing.get("env") == env_map):
                return {"action": "already_configured", "client": client, "path": cfg_path, "status": "ALREADY_CONFIGURED"}

    backup_path = None
    if CLIENT_SPECS[client]["type"] == "json":
        data = read_json_config(cfg_path)
        if client == "opencode":
            if "$schema" not in data:
                data["$schema"] = "https://opencode.ai/config.json"
            mcp = data.setdefault("mcp", {})
            if "servers" in mcp and isinstance(mcp["servers"], dict):
                target_map = mcp["servers"]
            else:
                target_map = mcp

            if url:
                entry = {
                    "type": "remote",
                    "url": url,
                    "oauth": False,
                }
                if token:
                    entry["headers"] = {"Authorization": f"Bearer {token}"}
                target_map[server_name] = entry
            else:
                entry = {
                    "type": "local",
                    "command": [bin_path] + args,
                    "enabled": True,
                }
                if env_map:
                    entry["env"] = env_map
                target_map[server_name] = entry
        else:
            servers = data.setdefault("mcpServers", {})
            if url:
                entry = {
                    "serverUrl": url,
                    "disabled": False,
                }
                if token:
                    entry["headers"] = {"Authorization": f"Bearer {token}"}
                servers[server_name] = entry
            else:
                entry = {
                    "command": bin_path,
                    "args": args,
                }
                if env_map:
                    entry["env"] = env_map
                servers[server_name] = entry

        content, backup_path = write_json_config(cfg_path, data, dry_run=dry_run)

    elif CLIENT_SPECS[client]["type"] == "toml":
        raw_content = ""
        if os.path.exists(cfg_path):
            with open(cfg_path, "r", encoding="utf-8") as f:
                raw_content = f.read()

        new_toml = update_toml_server(
            raw_content,
            server_name=server_name,
            bin_path=bin_path,
            args=args,
            env=env_map,
            url=url,
            token=token,
            remove=False,
        )

        if dry_run:
            content = new_toml
        else:
            os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
            backup_path = make_backup(cfg_path)
            with open(cfg_path, "w", encoding="utf-8") as f:
                f.write(new_toml)
            content = new_toml

    return {
        "action": "dry_run" if dry_run else "configured",
        "client": client,
        "path": cfg_path,
        "binary": bin_path,
        "server": server_name,
        "workspace": workspace or "",
        "backup_path": backup_path,
        "status": "DRY_RUN" if dry_run else "SUCCESS",
        "content": content,
    }


def remove_client(client, config_override=None, server_name="zenf", dry_run=False):
    cfg_path = get_config_path(client, config_override)
    if not os.path.exists(cfg_path):
        return {"action": "not_found", "client": client, "path": cfg_path}

    if CLIENT_SPECS[client]["type"] == "json":
        data = read_json_config(cfg_path)
        removed = False
        if client == "opencode":
            mcp = data.get("mcp", {})
            if isinstance(mcp, dict):
                if "servers" in mcp and isinstance(mcp["servers"], dict) and server_name in mcp["servers"]:
                    del mcp["servers"][server_name]
                    removed = True
                elif server_name in mcp:
                    del mcp[server_name]
                    removed = True
        else:
            servers = data.get("mcpServers", {})
            if isinstance(servers, dict) and server_name in servers:
                del servers[server_name]
                removed = True

        if removed:
            _, backup_path = write_json_config(cfg_path, data, dry_run=dry_run)
            act = "dry_run" if dry_run else "removed"
            return {"action": act, "client": client, "path": cfg_path, "backup_path": backup_path, "status": "SUCCESS"}
        return {"action": "not_configured", "client": client, "path": cfg_path, "status": "NOT_CONFIGURED"}

    elif CLIENT_SPECS[client]["type"] == "toml":
        with open(cfg_path, "r", encoding="utf-8") as f:
            raw_content = f.read()
        new_toml = update_toml_server(raw_content, server_name=server_name, bin_path="", args=[], remove=True)
        if new_toml != raw_content:
            backup_path = None
            if not dry_run:
                backup_path = make_backup(cfg_path)
                with open(cfg_path, "w", encoding="utf-8") as f:
                    f.write(new_toml)
            act = "dry_run" if dry_run else "removed"
            return {"action": act, "client": client, "path": cfg_path, "backup_path": backup_path, "status": "SUCCESS"}
        return {"action": "not_configured", "client": client, "path": cfg_path, "status": "NOT_CONFIGURED"}


def print_status_table(results):
    c_cyan = "\033[1;36m"
    c_green = "\033[1;32m"
    c_yellow = "\033[1;33m"
    c_red = "\033[1;31m"
    c_dim = "\033[90m"
    c_bold = "\033[1m"
    c_reset = "\033[0m"

    term_cols = shutil.get_terminal_size((80, 24)).columns
    box_w = min(term_cols, 84)
    if box_w < 50:
        box_w = 50

    print(f"\n{c_bold}{c_cyan}=== ZENCLI MCP CLIENT INTEGRATION AUDIT ==={c_reset}")
    print(f"{c_dim}SSOT Reference: https://github.com/venhdev/zenforge/blob/main/MCP.md{c_reset}\n")

    for r in results:
        client = r["client"]
        status_raw = r["status"]
        servers = r.get("servers", {})
        count = r.get("total_servers", 0)

        path_disp = r["config_path"]
        home = os.path.expanduser("~")
        if path_disp.startswith(home):
            path_disp = "~" + path_disp[len(home):]

        if status_raw.startswith("ERROR:"):
            badge = f"{c_red}✗ ERROR{c_reset}"
            summary = f"{c_red}{status_raw}{c_reset}"
        elif status_raw == "FILE_MISSING":
            badge = f"{c_dim}○ FILE_MISSING{c_reset}"
            summary = f"{c_dim}(Config file not created yet){c_reset}"
        elif status_raw == "NOT_CONFIGURED" or count == 0:
            badge = f"{c_red}✗ NOT_CONFIGURED{c_reset}"
            summary = f"{c_dim}(No active MCP servers){c_reset}"
        elif status_raw == "BINARY_MISSING":
            badge = f"{c_yellow}⚠ {count} SERVER{'S' if count > 1 else ''}{c_reset}"
            summary = ""
        else:
            badge = f"{c_green}✔ {count} SERVER{'S' if count > 1 else ''}{c_reset}"
            summary = ""

        # Row 1: Client identifier, badge, and config file path
        print(f" {c_bold}{client:<12}{c_reset} {badge:<28} {c_dim}{path_disp}{c_reset}")

        # Row 2+: Servers or clean summary note
        if summary:
            print(f"    {summary}")
        else:
            for s_name, s in servers.items():
                s_status = s.get("status", "CONFIGURED")
                if s_status == "CONFIGURED":
                    s_badge = f"{c_green}✔ CONFIGURED{c_reset}"
                else:
                    s_badge = f"{c_yellow}⚠ BINARY_MISSING{c_reset}"

                if s.get("transport") == "http":
                    target_cmd = f"http: {s.get('url', '')}"
                else:
                    cmd_str = os.path.basename(s.get("binary_path", ""))
                    if s.get("args"):
                        cmd_str += " " + " ".join(s["args"][:3])
                        if len(s["args"]) > 3:
                            cmd_str += "..."
                    target_cmd = cmd_str or "-"

                max_cmd_w = box_w - 38
                if max_cmd_w > 12 and len(target_cmd) > max_cmd_w:
                    target_cmd = target_cmd[:max_cmd_w - 3] + "..."

                print(f"    • {c_cyan}{s_name:<12}{c_reset} {target_cmd:<{max_cmd_w}} {s_badge}")
        print()


def parse_env_args(env_list):
    res = {}
    if not env_list:
        return res
    for item in env_list:
        if "=" in item:
            k, v = item.split("=", 1)
            res[k.strip()] = v.strip()
    return res


def resolve_clients(client_str):
    if not client_str or client_str in ("all", ""):
        return ALL_CLIENTS
    targets = []
    for c in client_str.split(","):
        c = c.strip().lower()
        if c:
            if c not in CLIENT_SPECS:
                print(f"❌ Unsupported client: '{c}'. Supported: {', '.join(ALL_CLIENTS)}", file=sys.stderr)
                sys.exit(1)
            targets.append(c)
    return targets


def main():
    raw_argv = sys.argv[1:]
    trailing_cmd = []
    if "--" in raw_argv:
        dd_idx = raw_argv.index("--")
        trailing_cmd = raw_argv[dd_idx + 1:]
        raw_argv = raw_argv[:dd_idx]

    parser = argparse.ArgumentParser(
        prog="zencli mcp",
        description="Unified MCP Configuration Orchestrator for AI Agent Tools (OpenCode, Antigravity, Claude Code, Codex, Cursor).",
    )
    subparsers = parser.add_subparsers(dest="command", help="MCP Subcommands")

    # clients (aliases: list, ls)
    clients_p = subparsers.add_parser("clients", aliases=["list", "ls"], help="List supported AI clients and canonical config paths")
    clients_p.add_argument("--json", action="store_true", help="Output as JSON")

    # presets
    preset_p = subparsers.add_parser("presets", help="List built-in MCP presets (ZenForge, SQLite, GitHub, Fetch, Filesystem, Postgres)")
    preset_p.add_argument("--json", action="store_true", help="Output as JSON")

    # check / status
    check_p = subparsers.add_parser("check", aliases=["status"], help="Audit MCP configuration status for client(s)")
    check_p.add_argument("client", nargs="?", default="all", help="Target client: opencode, agy, claude, codex, cursor, all (default: all)")
    check_p.add_argument("-c", "--config", help="Override client config path")
    check_p.add_argument("-s", "--server", default=None, help="Specific server entry name to check (default: check all configured servers)")
    check_p.add_argument("--json", action="store_true", help="Output audit results as JSON")

    # setup (backwards compatibility for zenforge)
    setup_p = subparsers.add_parser("setup", help="Configure zenf MCP server entry in client configuration")
    setup_p.add_argument("client", nargs="?", default="all", help="Target client: opencode, agy, claude, codex, cursor, all (default: all)")
    setup_p.add_argument("-w", "--workspace", default="default", help="Workspace alias (default: default)")
    setup_p.add_argument("-b", "--binary", help="Path to zenf binary (auto-detected if omitted)")
    setup_p.add_argument("-s", "--server", default="zenf", help="Server entry name (default: zenf)")
    setup_p.add_argument("-c", "--config", help="Override client config path")
    setup_p.add_argument("--url", help="Configure for remote Streamable HTTP transport")
    setup_p.add_argument("--token", help="Bearer token for remote HTTP transport")
    setup_p.add_argument("-f", "--force", action="store_true", help="Force overwrite existing entry")
    setup_p.add_argument("-n", "--dry-run", action="store_true", help="Preview configuration changes without writing")
    setup_p.add_argument("-a", "--all", action="store_true", help="Apply to all supported clients")

    # add (universal / generic & preset)
    add_p = subparsers.add_parser("add", help="Add an MCP server (generic command or preset) to AI client(s)")
    add_p.add_argument("target", help="Server name or preset identifier (zenforge, sqlite, github, fetch, filesystem, postgres)")
    add_p.add_argument("-c", "--client", default="all", help="Target client(s), comma-separated (e.g. codex,claude) or 'all' (default: all)")
    add_p.add_argument("-s", "--server", help="Server entry name in config (default: target name)")
    add_p.add_argument("--config", help="Override client config path")
    add_p.add_argument("-w", "--workspace", default="default", help="Workspace alias (for zenforge preset)")
    add_p.add_argument("-b", "--binary", help="Binary path (for zenforge preset)")
    add_p.add_argument("--token", help="Token/API Key (for github preset or remote auth)")
    add_p.add_argument("--db", help="Database path (for sqlite preset)")
    add_p.add_argument("--path", help="Allowed directory path (for filesystem preset)")
    add_p.add_argument("--conn", help="Connection string (for postgres preset)")
    add_p.add_argument("--env", action="append", help="Environment variables KEY=VALUE (repeatable)")
    add_p.add_argument("--url", help="Configure for remote Streamable HTTP transport")
    add_p.add_argument("-f", "--force", action="store_true", help="Force overwrite existing entry")
    add_p.add_argument("-n", "--dry-run", action="store_true", help="Preview configuration changes without writing")
    add_p.add_argument("-a", "--all", action="store_true", help="Apply to all supported clients")

    # remove
    rm_p = subparsers.add_parser("remove", aliases=["rm"], help="Remove MCP server entry from client configuration")
    rm_p.add_argument("target", help="Server name (e.g. zenf, sqlite) or client name (e.g. codex, claude)")
    rm_p.add_argument("-c", "--client", default=None, help="Target client(s), comma-separated or 'all'")
    rm_p.add_argument("--config", help="Override client config path")
    rm_p.add_argument("-s", "--server", "--server-name", dest="server", help="Server entry name to remove (default: zenf or target)")
    rm_p.add_argument("-n", "--dry-run", action="store_true", help="Preview removal without modifying files")
    rm_p.add_argument("-a", "--all", action="store_true", help="Remove from all supported clients")

    args = parser.parse_args(raw_argv)

    if not args.command:
        parser.print_help()
        sys.exit(0)

    cmd = args.command
    if cmd in ("clients", "list", "ls"):
        out = {k: {"name": v["name"], "config_path": v["default_path"]()} for k, v in CLIENT_SPECS.items()}
        if getattr(args, "json", False):
            print(json.dumps(out, indent=2))
        else:
            print("\nSupported AI Clients & Canonical MCP Config Paths:")
            for k, v in out.items():
                print(f"  • {k:<10} ({v['name']}): {v['config_path']}")
            print()
        return

    if cmd == "presets":
        out = {k: {"name": v["name"], "package": v.get("package", ""), "description": v["description"]} for k, v in PRESET_CATALOG.items()}
        if getattr(args, "json", False):
            print(json.dumps(out, indent=2))
        else:
            print("\nAvailable Built-in MCP Presets:")
            for k, v in out.items():
                pkg = f"({v['package']})" if v.get("package") else f"({v['name']})"
                print(f"  • {k:<12} {pkg:<45} - {v['description']}")
            print()
        return

    if cmd in ("check", "status"):
        target_clients = ALL_CLIENTS if args.client in ("all", "", None) else resolve_clients(args.client)
        results = [check_client(c, config_override=args.config if len(target_clients) == 1 else None, server_name=args.server) for c in target_clients]
        if getattr(args, "json", False):
            print(json.dumps(results if len(results) > 1 else results[0], indent=2))
        else:
            print_status_table(results)
        return

    if cmd in ("setup", "add"):
        env_map = parse_env_args(getattr(args, "env", None))
        is_add = (cmd == "add")
        target = args.target if is_add else "zenforge"
        client_arg = getattr(args, "client", "all") or "all"
        if getattr(args, "all", False):
            client_arg = "all"
        target_clients = resolve_clients(client_arg)

        # Resolve server definition: either Generic (trailing_cmd) or Preset
        if trailing_cmd:
            server_name = getattr(args, "server", None) or target
            server_cmd = trailing_cmd[0]
            server_args = trailing_cmd[1:]
        elif target in PRESET_CATALOG:
            preset = PRESET_CATALOG[target]
            server_name = getattr(args, "server", None) or preset["default_server_name"]
            built = preset["builder"](
                workspace=getattr(args, "workspace", None),
                binary=getattr(args, "binary", None),
                token=getattr(args, "token", None),
                db=getattr(args, "db", None),
                path=getattr(args, "path", None),
                conn=getattr(args, "conn", None),
                env=env_map,
            )
            server_cmd = built["command"]
            server_args = built["args"]
            env_map = built["env"]
        elif target == "zenf":
            preset = PRESET_CATALOG["zenforge"]
            server_name = getattr(args, "server", None) or "zenf"
            built = preset["builder"](workspace=getattr(args, "workspace", None), binary=getattr(args, "binary", None), env=env_map)
            server_cmd = built["command"]
            server_args = built["args"]
        else:
            print(f"❌ Error: '{target}' is not a recognized preset and no command was specified after '--'.", file=sys.stderr)
            print("💡 Usage: zmcp add <name> [flags] -- <command> [args...]", file=sys.stderr)
            print("   Or use a built-in preset: zmcp presets", file=sys.stderr)
            sys.exit(1)

        for c in target_clients:
            cfg_override = getattr(args, "config", None) if len(target_clients) == 1 else None
            res = setup_client(
                c,
                config_override=cfg_override,
                server_name=server_name,
                command=server_cmd,
                args=server_args,
                env=env_map,
                workspace=getattr(args, "workspace", None),
                url=getattr(args, "url", None),
                token=getattr(args, "token", None),
                force=getattr(args, "force", False),
                dry_run=getattr(args, "dry_run", False),
            )
            if res["action"] == "dry_run":
                print(f"[DRY-RUN] Preview for {c} ({res['path']}):\n{res['content']}")
            elif res["action"] == "already_configured":
                print(f"[ALREADY_CONFIGURED] {c} is already configured with '{server_name}' in {res['path']}")
            else:
                print(f"[SUCCESS] Configured {c} with '{server_name}' in {res['path']}")
                if res.get("backup_path"):
                    print(f"         Backup: {res['backup_path']}")
                if not getattr(args, "url", None):
                    print(f"         Command: {res['binary']}")
        return

    if cmd in ("remove", "rm"):
        target = args.target.strip()
        client_arg = getattr(args, "client", None)
        all_flag = getattr(args, "all", False)

        if all_flag:
            target_clients = ALL_CLIENTS
            server_to_rm = args.server or target
        elif client_arg is not None:
            # Explicit -c/--client provided: target is the server name
            target_clients = ALL_CLIENTS if client_arg == "all" else resolve_clients(client_arg)
            server_to_rm = args.server or target
        else:
            # -c was not specified; check if positional target refers to client name
            if target.lower() in CLIENT_SPECS:
                target_clients = [target.lower()]
                server_to_rm = args.server or "zenf"
            elif target.lower() == "all":
                target_clients = ALL_CLIENTS
                server_to_rm = args.server or "zenf"
            else:
                target_clients = ALL_CLIENTS
                server_to_rm = args.server or target

        for c in target_clients:
            cfg_override = getattr(args, "config", None) if len(target_clients) == 1 else None
            res = remove_client(c, config_override=cfg_override, server_name=server_to_rm, dry_run=getattr(args, "dry_run", False))
            if res["action"] == "dry_run":
                print(f"[DRY-RUN] Would remove '{server_to_rm}' from {c} in {res['path']}")
            elif res["action"] == "removed":
                print(f"[SUCCESS] Removed '{server_to_rm}' from {c} in {res['path']}")
                if res.get("backup_path"):
                    print(f"         Backup: {res['backup_path']}")
            elif res["action"] == "not_configured":
                print(f"[INFO] '{server_to_rm}' was not configured in {c} ({res['path']})")
            else:
                print(f"[INFO] Config file for {c} not found ({res['path']})")
        return


if __name__ == "__main__":
    main()
