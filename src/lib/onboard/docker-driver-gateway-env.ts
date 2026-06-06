// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { generateKeyPairSync, randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  GATEWAY_BIND_ADDRESS,
  WILDCARD_GATEWAY_BIND_ADDRESS,
  getGatewayConnectHost,
  getGatewayHttpEndpoint,
  getGatewayHttpsEndpoint,
} from "../core/gateway-address";
import { GATEWAY_PORT } from "../core/ports";
import {
  hasOpenShellGatewayUserService,
  startPackageManagedDockerDriverGateway,
  type PackageManagedDockerDriverGatewayOptions,
} from "./docker-driver-gateway-service";

export { getGatewayHttpsEndpoint };
export { startPackageManagedDockerDriverGateway };

export const DOCKER_DRIVER_GATEWAY_RUNTIME_ENV_KEYS = [
  "OPENSHELL_DRIVERS",
  "OPENSHELL_BIND_ADDRESS",
  "OPENSHELL_SERVER_PORT",
  "OPENSHELL_DISABLE_TLS",
  "OPENSHELL_DISABLE_GATEWAY_AUTH",
  "OPENSHELL_LOCAL_TLS_DIR",
  "OPENSHELL_DB_URL",
  "OPENSHELL_GRPC_ENDPOINT",
  "OPENSHELL_SSH_GATEWAY_HOST",
  "OPENSHELL_SSH_GATEWAY_PORT",
  "OPENSHELL_DOCKER_NETWORK_NAME",
  "OPENSHELL_DOCKER_SUPERVISOR_IMAGE",
  "OPENSHELL_DOCKER_SUPERVISOR_BIN",
  "OPENSHELL_VM_DRIVER_STATE_DIR",
  "OPENSHELL_DRIVER_DIR",
] as const;

export interface BuildDockerDriverGatewayEnvOptions {
  platform?: NodeJS.Platform;
  stateDir: string;
  dockerNetworkName?: string;
  getDockerSupervisorImage: () => string;
  resolveSandboxBin: () => string | null;
}

export interface DockerDriverGatewayJwtMaterial {
  tlsDir: string;
  signingKeyPath: string;
  publicKeyPath: string;
  kidPath: string;
}

export type PackageManagedDockerDriverGatewayWithEnvOverrideOptions = Omit<
  PackageManagedDockerDriverGatewayOptions,
  "prepareOpenShellGatewayUserServiceEnv"
> & {
  gatewayEnv: Record<string, string>;
};

export function getGatewayPortCheckOptions(): { host: string } {
  return { host: GATEWAY_BIND_ADDRESS };
}

export function getGatewayStartNetworkEnv(): Record<string, string> {
  return {
    OPENSHELL_BIND_ADDRESS: GATEWAY_BIND_ADDRESS,
    OPENSHELL_SERVER_PORT: String(GATEWAY_PORT),
    OPENSHELL_SSH_GATEWAY_HOST: getGatewayConnectHost(),
    OPENSHELL_SSH_GATEWAY_PORT: String(GATEWAY_PORT),
  };
}

export function getDockerDriverGatewayEndpoint(): string {
  return getGatewayHttpEndpoint();
}

export function warnIfGatewayWildcardBindAddress(): void {
  if (GATEWAY_BIND_ADDRESS !== WILDCARD_GATEWAY_BIND_ADDRESS) return;
  console.log(
    "  ! OpenShell gateway bind address set to 0.0.0.0; the gateway may be reachable from other hosts on this network.",
  );
}

export function buildDockerDriverGatewayEnv({
  platform = process.platform,
  stateDir,
  dockerNetworkName = "openshell-docker",
  getDockerSupervisorImage,
  resolveSandboxBin,
}: BuildDockerDriverGatewayEnvOptions): Record<string, string> {
  const env: Record<string, string> = {
    OPENSHELL_DRIVERS: "docker",
    ...getGatewayStartNetworkEnv(),
    OPENSHELL_DISABLE_TLS: "true",
    OPENSHELL_DISABLE_GATEWAY_AUTH: "false",
    OPENSHELL_LOCAL_TLS_DIR: getDockerDriverGatewayTlsDir(stateDir),
    OPENSHELL_DB_URL: `sqlite:${path.join(stateDir, "openshell.db")}`,
    OPENSHELL_GRPC_ENDPOINT: getDockerDriverGatewayEndpoint(),
    OPENSHELL_DOCKER_NETWORK_NAME: dockerNetworkName,
    OPENSHELL_DOCKER_SUPERVISOR_IMAGE: getDockerSupervisorImage(),
  };
  if (platform === "linux") {
    const sandboxBin = resolveSandboxBin();
    if (sandboxBin) {
      env.OPENSHELL_DOCKER_SUPERVISOR_BIN = sandboxBin;
    }
  }
  return env;
}

export function getDockerDriverGatewayTlsDir(stateDir: string): string {
  return path.join(stateDir, "tls");
}

export function getDockerDriverGatewayJwtMaterial(
  stateDir: string,
): DockerDriverGatewayJwtMaterial {
  const tlsDir = getDockerDriverGatewayTlsDir(stateDir);
  const jwtDir = path.join(tlsDir, "jwt");
  return {
    tlsDir,
    signingKeyPath: path.join(jwtDir, "signing.pem"),
    publicKeyPath: path.join(jwtDir, "public.pem"),
    kidPath: path.join(jwtDir, "kid"),
  };
}

export function ensureDockerDriverGatewayJwtMaterial(
  stateDir: string,
): DockerDriverGatewayJwtMaterial {
  const material = getDockerDriverGatewayJwtMaterial(stateDir);
  const files = [material.signingKeyPath, material.publicKeyPath, material.kidPath];
  const present = files.filter((file) => fs.existsSync(file)).length;
  if (present === files.length) return material;
  if (present !== 0) {
    throw new Error(
      `Partial OpenShell sandbox JWT material in ${path.dirname(material.signingKeyPath)}; expected signing.pem, public.pem, and kid`,
    );
  }

  fs.mkdirSync(path.dirname(material.signingKeyPath), { recursive: true, mode: 0o700 });
  fs.chmodSync(material.tlsDir, 0o700);
  fs.chmodSync(path.dirname(material.signingKeyPath), 0o700);
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  fs.writeFileSync(
    material.signingKeyPath,
    privateKey.export({ type: "pkcs8", format: "pem" }),
    { encoding: "utf-8", mode: 0o600 },
  );
  fs.writeFileSync(
    material.publicKeyPath,
    publicKey.export({ type: "spki", format: "pem" }),
    { encoding: "utf-8", mode: 0o644 },
  );
  fs.writeFileSync(material.kidPath, `${randomBytes(16).toString("hex")}\n`, {
    encoding: "utf-8",
    mode: 0o644,
  });
  return material;
}

export function buildDockerGatewayDebEnvFile(
  existing: string,
  override: Record<string, string>,
): string {
  const managedKeyPattern = new RegExp(
    `^(${DOCKER_DRIVER_GATEWAY_RUNTIME_ENV_KEYS.join("|")})=`,
  );
  const preserved = existing
    .split("\n")
    .filter((line) => line.trim() && !managedKeyPattern.test(line));
  const managed = DOCKER_DRIVER_GATEWAY_RUNTIME_ENV_KEYS.flatMap((key) =>
    typeof override[key] === "string"
      ? [formatEnvironmentFileAssignment(key, override[key])]
      : [],
  );
  return `${[...preserved, ...managed].join("\n")}\n`;
}

function formatEnvironmentFileAssignment(key: string, value: string): string {
  if (/[\0\r\n]/.test(value)) {
    throw new Error(`Invalid OpenShell gateway env value for ${key}: contains a line break`);
  }
  return `${key}=${value}`;
}

function readTextFileIfPresent(filePath: string): string {
  try {
    return fs.readFileSync(filePath, "utf-8");
  } catch (error) {
    if (
      error instanceof Error &&
      "code" in error &&
      (error as NodeJS.ErrnoException).code === "ENOENT"
    ) {
      return "";
    }
    throw error;
  }
}

export function writeDockerGatewayDebEnvOverride(
  getOverride: () => Record<string, string>,
  opts: Parameters<typeof hasOpenShellGatewayUserService>[0] = {},
): boolean {
  if (!hasOpenShellGatewayUserService(opts)) return false;
  const override = getOverride();
  const envDir = path.join(os.homedir(), ".config", "openshell");
  const envFile = path.join(envDir, "gateway.env");
  fs.mkdirSync(envDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(envDir, 0o700);
  const existing = readTextFileIfPresent(envFile);
  fs.writeFileSync(envFile, buildDockerGatewayDebEnvFile(existing, override), {
    encoding: "utf-8",
    mode: 0o600,
  });
  fs.chmodSync(envFile, 0o600);
  return true;
}

export function writeDockerGatewayDebEnvOverrideOrThrow(
  getOverride: () => Record<string, string>,
  opts: Parameters<typeof hasOpenShellGatewayUserService>[0] = {},
): void {
  if (!writeDockerGatewayDebEnvOverride(getOverride, opts)) {
    throw new Error("OpenShell gateway user service env file is not available");
  }
}

export function startPackageManagedDockerDriverGatewayWithEnvOverride({
  gatewayEnv,
  ...options
}: PackageManagedDockerDriverGatewayWithEnvOverrideOptions): Promise<boolean> {
  return startPackageManagedDockerDriverGateway({
    ...options,
    prepareOpenShellGatewayUserServiceEnv: () =>
      writeDockerGatewayDebEnvOverrideOrThrow(() => gatewayEnv),
  });
}
