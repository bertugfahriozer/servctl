# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`srvctl` is a CLI-only, security-hardened server management tool written entirely in **Bash**, targeting **Ubuntu 22.04 LTS** running as root (PHP-FPM, Nginx, MariaDB, Redis). It provisions per-domain isolation (separate Linux user, chroot, AppArmor, FPM pool, DB/Redis ACLs) plus server-wide hardening (ModSecurity WAF, seccomp, cgroups v2, AIDE, ClamAV). See [README.md](README.md) for the full command/security-layer reference.

There is **no build step, no test suite, and no CI/lint tooling**. `shellcheck` directives appear inline (`# shellcheck disable=...`) but nothing enforces them. The tool cannot meaningfully run on the macOS dev machine — it expects a root Ubuntu host with systemd, nginx, php-fpm, etc.

## Repo layout vs. runtime layout (important)

The repository is the **source**, not the install. [install.sh](install.sh) copies `bin/`, `lib/`, `templates/`, `conf/` into **`/usr/local/srvctl/`** and symlinks `bin/srvctl` → `/usr/local/bin/srvctl`. `SRVCTL_ROOT` is hardcoded to `/usr/local/srvctl` in both [bin/srvctl](bin/srvctl) and [lib/core.sh](lib/core.sh).

Consequences:
- Editing files in this repo does **not** affect an installed instance until `sudo bash install.sh` is re-run.
- `install.sh` preserves an existing `conf/srvctl.conf` across reinstalls (backs it up to `/tmp/srvctl.conf.bak`).
- Runtime state lives outside the repo: per-domain dirs under `/var/www/<domain>/`, logs under `/usr/local/srvctl/logs/`, secrets in `/var/www/<domain>/.credentials` (root:600).

## Architecture

Command flow: `bin/srvctl <cmd>` → sources [lib/core.sh](lib/core.sh) → loads plugins → a `case` dispatches to `_load_and_run <module> cmd_<module>`, which **sources only that one `lib/<module>.sh`** and calls its `cmd_<module>` function. Modules are lazy-loaded per invocation; they are not all sourced at startup.

Each `lib/<module>.sh` follows the same shape:
- A public `cmd_<module>()` entry that (usually) calls `require_root` then `case "${1:-help}"` to route subcommands.
- Private `_<module>_<action>()` functions implementing each subcommand.

[lib/core.sh](lib/core.sh) is the shared contract every module depends on (it is always sourced first). Key helpers to reuse rather than reinvent:
- Logging/UI: `info` `success` `warn` `error` (note: **`error` exits**) `step` `header` `divider`, plus color vars (`RED`, `GREEN`, `BOLD`, `NC`, …).
- `require_root` — call at the top of any mutating command.
- `load_config` — sources `conf/srvctl.conf` and applies defaults; **runs automatically at source time**, so `DEFAULT_PHP_VERSION`, `WEB_ROOT`, `SSH_PORT`, `BACKUP_DIR`, etc. are available everywhere.
- `safe_name` — `example.com` → `example_com`; this is the basis for derived identities: web user `web_<safe>`, DB user/name `usr_<safe>`/`db_<safe>`, FPM pool, AppArmor profile.
- `generate_password`, `render_template`, `domain_exists`, `list_all_domains`, `read_credentials` (sources `.credentials` to expose DB/Redis secrets), `php_version_exists`, `nginx_test`, `service_is_active`, `log_action`.

**Cross-module calls** are done by sourcing on demand, guarded so a missing module is non-fatal — e.g. modules that send alerts do `source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true` before calling `send_notification`. Follow this pattern instead of sourcing other modules at file top.

**Templates** in `templates/` (nginx, php-fpm, apparmor, logrotate, cgroups, seccomp) use `{{TOKEN}}` placeholders rendered by `render_template <file> KEY=value ...`. Note `install.sh` currently only copies the `nginx php-fpm apparmor logrotate` template subdirs — `cgroups` and `seccomp` are in the repo but not in the install loop.

## Conventions to match when editing

- **All user-facing strings and code comments are in Turkish.** Keep new output and comments Turkish to stay consistent (e.g. section banners, `info`/`error` messages).
- `confirm()` and the install/OS prompts expect the literal answer **`evet`** (Turkish "yes"), not `y`/`yes`.
- Every script starts with `set -euo pipefail`. Be deliberate about commands that may fail (append `|| true` where a non-zero exit is expected).
- Reuse `core.sh` helpers for output and config; don't hand-roll color codes or re-read the config file.
- Use `_<module>_<action>` naming for new subcommand handlers and wire them into the module's `case` block (and ideally the help text + `completions/srvctl.bash` / `completions/srvctl.zsh`).

## Version note

The live version string comes from `SRVCTL_VERSION` in [lib/core.sh](lib/core.sh) (currently `1.0.0`), which is what `srvctl version` prints. The header comment in [bin/srvctl](bin/srvctl) and the README say `2.0.0`. If bumping the version, update `core.sh` — that is the source of truth.
