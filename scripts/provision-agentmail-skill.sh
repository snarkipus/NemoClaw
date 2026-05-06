#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/provision-agentmail-skill.sh <sandbox-name> <agentmail-skill-dir>

Install a pinned local AgentMail SKILL.md bundle into a running OpenClaw
sandbox and enable its OpenClaw skill config. This intentionally avoids
runtime npx/pip installs and does not edit openclaw.json directly from the host.

Example:
  scripts/provision-agentmail-skill.sh my-assistant-v9 \
    /root/repos/integration-ops/artifacts/agentmail-skills/agentmail-skills-6631a0a/agentmail
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

SANDBOX_NAME=${1:-}
SKILL_DIR=${2:-}

[[ -n "$SANDBOX_NAME" ]] || die "missing sandbox name"
[[ -n "$SKILL_DIR" ]] || die "missing AgentMail skill directory"
[[ -d "$SKILL_DIR" ]] || die "skill directory not found: $SKILL_DIR"
[[ -f "$SKILL_DIR/SKILL.md" ]] || die "SKILL.md not found in: $SKILL_DIR"

NEMOCLAW_BIN=${NEMOCLAW_BIN:-nemoclaw}
OPENSHELL_BIN=${OPENSHELL_BIN:-openshell}

command -v "$NEMOCLAW_BIN" >/dev/null 2>&1 || die "nemoclaw binary not found: $NEMOCLAW_BIN"
command -v "$OPENSHELL_BIN" >/dev/null 2>&1 || die "openshell binary not found: $OPENSHELL_BIN"

printf '[agentmail] installing skill bundle from %s\n' "$SKILL_DIR" >&2
"$NEMOCLAW_BIN" "$SANDBOX_NAME" skill install "$SKILL_DIR"

printf '[agentmail] enabling OpenClaw skill config\n' >&2
"$OPENSHELL_BIN" sandbox exec --name "$SANDBOX_NAME" -- \
  openclaw config set skills.entries.agentmail.enabled true
"$OPENSHELL_BIN" sandbox exec --name "$SANDBOX_NAME" -- \
  openclaw config set skills.entries.agentmail.env.AGENTMAIL_API_KEY \
  openshell:resolve:env:AGENTMAIL_API_KEY

printf '[agentmail] verifying provisioned files and config\n' >&2
"$OPENSHELL_BIN" sandbox exec --name "$SANDBOX_NAME" -- \
  test -f /sandbox/.openclaw/skills/agentmail/SKILL.md
"$OPENSHELL_BIN" sandbox exec --name "$SANDBOX_NAME" -- \
  python3 -c 'import json; cfg=json.load(open("/sandbox/.openclaw/openclaw.json")); entry=cfg.get("skills",{}).get("entries",{}).get("agentmail",{}); assert entry.get("enabled") is True; assert entry.get("env",{}).get("AGENTMAIL_API_KEY") == "openshell:resolve:env:AGENTMAIL_API_KEY"'

printf '[agentmail] provision complete\n' >&2
