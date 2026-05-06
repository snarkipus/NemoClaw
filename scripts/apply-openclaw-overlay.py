#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import json
from pathlib import Path


CONFIG_PATH = Path("/sandbox/.openclaw/openclaw.json")


def deep_merge(target, updates):
    for key, value in updates.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            deep_merge(target[key], value)
        else:
            target[key] = value
    return target


def main():
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))

    cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})[
        "primary"
    ] = "xiaomi/mimo-v2.5-pro"

    models = cfg.setdefault("models", {})
    models["mode"] = "merge"
    models["providers"] = {
        "xiaomi": {
        "api": "openai-completions",
        "apiKey": "unused",
        "baseUrl": "https://inference.local/v1",
        "models": [
            {
                "contextWindow": 1048576,
                "cost": {
                    "cacheRead": 0.2,
                    "cacheWrite": 0,
                    "input": 1,
                    "output": 3,
                },
                "id": "mimo-v2.5-pro",
                "input": ["text"],
                "maxTokens": 16384,
                "name": "Xiaomi MiMo V2.5 Pro",
                "reasoning": True,
            }
        ],
        }
    }

    plugin_entries = cfg.setdefault("plugins", {}).setdefault("entries", {})
    deep_merge(
        plugin_entries,
        {
            "xai": {
                "enabled": True,
                "config": {
                    "webSearch": {"apiKey": "openshell:resolve:env:XAI_API_KEY"},
                    "xSearch": {"enabled": True},
                },
            },
            "firecrawl": {
                "enabled": True,
                "config": {
                    "webFetch": {
                        "apiKey": "openshell:resolve:env:FIRECRAWL_API_KEY",
                        "baseUrl": "https://api.firecrawl.dev",
                        "onlyMainContent": True,
                        "maxAgeMs": 172800000,
                        "timeoutSeconds": 60,
                    }
                },
            },
            "memory-core": {
                "config": {
                    "dreaming": {
                        "enabled": True,
                        "frequency": "0 3 * * *",
                        "timezone": "America/New_York",
                    }
                }
            },
        },
    )
    plugin_entries["memory-wiki"] = {
        "enabled": True,
        "config": {
            "vaultMode": "bridge",
            "bridge": {
                "enabled": True,
                "readMemoryArtifacts": True,
                "indexDreamReports": True,
                "indexDailyNotes": True,
                "indexMemoryRoot": True,
                "followMemoryEvents": True,
            },
            "search": {"backend": "shared", "corpus": "all"},
            "context": {"includeCompiledDigestPrompt": False},
            "vault": {"renderMode": "obsidian"},
        },
    }

    deep_merge(
        cfg.setdefault("tools", {}).setdefault("web", {}),
        {
            "fetch": {"enabled": True, "provider": "firecrawl"},
            "search": {"enabled": True, "provider": "grok"},
        },
    )

    for channel_name in ("discord", "telegram"):
        channel = cfg.setdefault("channels", {}).get(channel_name)
        if not isinstance(channel, dict):
            continue
        channel["enabled"] = False
        accounts = channel.get("accounts")
        if not isinstance(accounts, dict):
            continue
        default_account = accounts.get("default")
        if isinstance(default_account, dict):
            default_account["enabled"] = False

    cfg.setdefault("discovery", {}).setdefault("mdns", {})["mode"] = "off"
    cfg["memory"] = {"backend": "qmd"}
    cfg.setdefault("env", {})["GITHUB_TOKEN"] = "openshell:resolve:env:GITHUB_TOKEN"

    CONFIG_PATH.write_text(f"{json.dumps(cfg, indent=2)}\n", encoding="utf-8")
    CONFIG_PATH.chmod(0o600)


if __name__ == "__main__":
    main()
