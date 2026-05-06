// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

describe("sandbox network interface fallback", () => {
  const src = fs.readFileSync(path.join(import.meta.dirname, "index.ts"), "utf-8");

  it("wraps os.networkInterfaces with a loopback fallback", () => {
    expect(src).toContain('Object.defineProperty(os, "networkInterfaces"');
    expect(src).toContain("uv_interface_addresses");
    expect(src).toContain('address: "127.0.0.1"');
    expect(src).toContain("[Sandbox Compatibility]");
  });
});
