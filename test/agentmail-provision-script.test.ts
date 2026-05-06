// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("AgentMail provision script", () => {
  const script = readFileSync("scripts/provision-agentmail-skill.sh", "utf8");
  const commandBody = script
    .slice(script.indexOf("die()"))
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("#"))
    .join("\n");

  it("uses host-side skill upload and OpenClaw-owned config mutation", () => {
    expect(script).toContain('"$NEMOCLAW_BIN" "$SANDBOX_NAME" skill install "$SKILL_DIR"');
    expect(script).toContain(
      "openclaw config set skills.entries.agentmail.enabled true",
    );
    expect(script).toContain(
      "openclaw config set skills.entries.agentmail.env.AGENTMAIL_API_KEY",
    );
    expect(script).toContain("openshell:resolve:env:AGENTMAIL_API_KEY");
  });

  it("keeps runtime package managers out of the baseline path", () => {
    expect(commandBody).not.toMatch(/\bnpx\b/);
    expect(commandBody).not.toMatch(/\bpip(?:3)?\s+install\b/);
    expect(commandBody).not.toMatch(/npm\s+install/);
  });
});
