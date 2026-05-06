// @ts-nocheck
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Regression guards for sandbox image provisioning.
//
// Verifies that the image-build sources (Dockerfile and Dockerfile.base)
// preserve the runtime-writable symlink layout introduced by #1027/#1519
// and the root-owned read-only config invariants from #514.
//
// These are static regression guards over the Dockerfile text — they fail
// immediately if a future refactor drops one of the baked-in provisioning
// steps, even before a full image build runs in CI.

import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const DOCKERFILE = path.join(ROOT, "Dockerfile");
const DOCKERFILE_BASE = path.join(ROOT, "Dockerfile.base");

describe("sandbox provisioning: exec-approvals / update-check symlinks (#1027, #1519)", () => {
  const src = fs.readFileSync(DOCKERFILE_BASE, "utf-8");

  it("Dockerfile.base creates the exec-approvals.json backing file in .openclaw-data", () => {
    // The data file has to exist before the symlink target resolves, so the
    // OpenClaw gateway can read+write through .openclaw/exec-approvals.json
    // without hitting EACCES.
    expect(src).toMatch(/touch \/sandbox\/\.openclaw-data\/exec-approvals\.json/);
  });

  it("Dockerfile.base symlinks .openclaw/exec-approvals.json -> .openclaw-data/exec-approvals.json", () => {
    expect(src).toContain(
      "ln -s /sandbox/.openclaw-data/exec-approvals.json /sandbox/.openclaw/exec-approvals.json",
    );
  });

  it("Dockerfile.base creates the update-check.json backing file in .openclaw-data", () => {
    expect(src).toMatch(/touch \/sandbox\/\.openclaw-data\/update-check\.json/);
  });

  it("Dockerfile.base symlinks .openclaw/update-check.json -> .openclaw-data/update-check.json", () => {
    expect(src).toContain(
      "ln -s /sandbox/.openclaw-data/update-check.json /sandbox/.openclaw/update-check.json",
    );
  });

  it("the exec-approvals data file is created before the symlink that points at it", () => {
    const dataIdx = src.indexOf("touch /sandbox/.openclaw-data/exec-approvals.json");
    const linkIdx = src.indexOf(
      "ln -s /sandbox/.openclaw-data/exec-approvals.json /sandbox/.openclaw/exec-approvals.json",
    );
    expect(dataIdx).toBeGreaterThanOrEqual(0);
    expect(linkIdx).toBeGreaterThan(dataIdx);
  });
});

describe("sandbox provisioning: qmd/wiki/tasks symlinks", () => {
  const baseSrc = fs.readFileSync(DOCKERFILE_BASE, "utf-8");
  const mainSrc = fs.readFileSync(DOCKERFILE, "utf-8");

  it("Dockerfile.base creates qmd/wiki/tasks backing directories in .openclaw-data", () => {
    expect(baseSrc).toContain("/sandbox/.openclaw-data/qmd");
    expect(baseSrc).toContain("/sandbox/.openclaw-data/tasks");
    expect(baseSrc).toContain("/sandbox/.openclaw-data/wiki");
  });

  it("Dockerfile.base symlinks qmd/wiki/tasks into .openclaw", () => {
    expect(baseSrc).toContain("ln -s /sandbox/.openclaw-data/qmd /sandbox/.openclaw/qmd");
    expect(baseSrc).toContain("ln -s /sandbox/.openclaw-data/tasks /sandbox/.openclaw/tasks");
    expect(baseSrc).toContain("ln -s /sandbox/.openclaw-data/wiki /sandbox/.openclaw/wiki");
  });

  it("Dockerfile keeps stale-base fallback scaffolding for qmd/wiki/tasks", () => {
    expect(mainSrc).toContain("/sandbox/.openclaw-data/qmd");
    expect(mainSrc).toContain("/sandbox/.openclaw-data/tasks");
    expect(mainSrc).toContain("/sandbox/.openclaw-data/wiki");
    expect(mainSrc).toMatch(
      /for dir in logs credentials sandbox media plugin-runtime-deps qmd tasks wiki/,
    );
  });
});

describe("sandbox provisioning: plugin-runtime-deps symlink", () => {
  const baseSrc = fs.readFileSync(DOCKERFILE_BASE, "utf-8");
  const mainSrc = fs.readFileSync(DOCKERFILE, "utf-8");

  it("Dockerfile.base creates the plugin-runtime-deps backing directory in .openclaw-data", () => {
    expect(baseSrc).toContain("/sandbox/.openclaw-data/plugin-runtime-deps");
  });

  it("Dockerfile.base symlinks plugin-runtime-deps into .openclaw", () => {
    expect(baseSrc).toContain(
      "ln -s /sandbox/.openclaw-data/plugin-runtime-deps /sandbox/.openclaw/plugin-runtime-deps",
    );
  });

  it("Dockerfile keeps stale-base fallback scaffolding for plugin-runtime-deps", () => {
    expect(mainSrc).toContain("/sandbox/.openclaw-data/plugin-runtime-deps");
    expect(mainSrc).toMatch(/for dir in logs credentials sandbox media plugin-runtime-deps qmd tasks wiki/);
  });
});

describe("sandbox provisioning: procps debug tools (#2343)", () => {
  const baseSrc = fs.readFileSync(DOCKERFILE_BASE, "utf-8");
  const mainSrc = fs.readFileSync(DOCKERFILE, "utf-8");

  it("Dockerfile.base installs procps in the apt-get layer", () => {
    expect(baseSrc).toMatch(/apt-get.*install.*procps/s);
  });

  it("Dockerfile has a procps fallback for stale GHCR base images", () => {
    // The hardening step must protect procps from autoremove and install it
    // if the base image predates the procps addition.
    expect(mainSrc).toMatch(/command -v ps/);
    expect(mainSrc).toMatch(/install.*procps/);
  });
});

describe("sandbox provisioning: staged rebuild runtime tools", () => {
  const src = fs.readFileSync(DOCKERFILE, "utf-8");

  it("keeps pinned version args for gh, obsidian-headless, and qmd", () => {
    expect(src).toContain("ARG GH_VERSION=2.91.0");
    expect(src).toContain("ARG OBSIDIAN_HEADLESS_VERSION=0.0.8");
    expect(src).toContain("ARG QMD_VERSION=2.1.0");
  });

  it("installs github cli in the staged Dockerfile path", () => {
    expect(src).toContain("https://cli.github.com/packages stable main");
    expect(src).toContain('apt-get install -y --no-install-recommends "gh=${GH_VERSION}"');
  });

  it("installs obsidian-headless and qmd after npm ci --omit=dev", () => {
    expect(src).toMatch(/RUN npm ci --omit=dev\s+RUN npm install -g --no-audit --no-fund --no-progress/s);
    expect(src).toContain('"obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}"');
    expect(src).toContain('"@tobilu/qmd@${QMD_VERSION}"');
  });
});

describe("sandbox provisioning: root-owned read-only config (#514)", () => {
  const src = fs.readFileSync(DOCKERFILE, "utf-8");

  it("openclaw.json stays mode 0444 (agent cannot tamper with auth token / CORS)", () => {
    expect(src).toContain("chmod 444 /sandbox/.openclaw/openclaw.json");
  });

  it(".config-hash stays root:root 0444 (agent cannot forge a matching integrity hash)", () => {
    expect(src).toContain("chown root:root /sandbox/.openclaw/.config-hash");
    expect(src).toContain("chmod 444 /sandbox/.openclaw/.config-hash");
  });

  it(".openclaw directory stays root:root 0755 (agent cannot add or replace symlinks)", () => {
    expect(src).toContain("chown root:root /sandbox/.openclaw");
    expect(src).toContain("chmod 755 /sandbox/.openclaw");
  });
});
