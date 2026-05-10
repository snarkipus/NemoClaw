# NemoClaw sandbox image — OpenClaw + NemoClaw plugin inside OpenShell
#
# Layers PR-specific code (plugin, blueprint, config, startup script) on top
# of the pre-built base image from GHCR. The base image contains all the
# expensive, rarely-changing layers (apt, gosu, users, openclaw CLI).
#
# For local builds without GHCR access, build the base first:
#   docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .

# Global ARG — must be declared before the first FROM to be visible
# to all FROM directives. Can be overridden via --build-arg.
ARG BASE_IMAGE=ghcr.io/nvidia/nemoclaw/sandbox-base:latest

# Stage 1: Build TypeScript plugin from source
FROM node:22-slim@sha256:4f77a690f2f8946ab16fe1e791a3ac0667ae1c3575c3e4d0d4589e9ed5bfaf3d AS builder
ENV NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false
COPY nemoclaw/package.json nemoclaw/package-lock.json nemoclaw/tsconfig.json /opt/nemoclaw/
COPY nemoclaw/src/ /opt/nemoclaw/src/
WORKDIR /opt/nemoclaw
RUN npm ci && npm run build

# Stage 2: Runtime image — pull cached base from GHCR
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# Harden: remove unnecessary build tools and network probes from base image (#830)
# Protect procps before autoremove — the GHCR base may predate the procps
# addition, leaving it absent or auto-marked. apt-mark + conditional install
# guarantees ps/top/kill are present regardless of base image staleness.
# Ref: #2343
# hadolint ignore=DL3001
RUN apt-mark manual procps 2>/dev/null || true \
    && (apt-get remove --purge -y gcc gcc-12 g++ g++-12 cpp cpp-12 make \
        netcat-openbsd netcat-traditional ncat 2>/dev/null || true) \
    && apt-get autoremove --purge -y \
    && if ! command -v ps >/dev/null 2>&1; then \
        apt-get update && apt-get install -y --no-install-recommends procps=2:4.0.2-3 \
        && rm -rf /var/lib/apt/lists/*; \
    else \
        rm -rf /var/lib/apt/lists/*; \
    fi \
    && ps --version

ARG GH_VERSION=2.92.0
ARG NEOVIM_VERSION=0.12.2
ARG NEOVIM_X86_64_SHA256=31cf85945cb600d96cdf69f88bc68bec814acbff50863c5546adef3a1bcef260
ARG NEOVIM_ARM64_SHA256=f697d4e4582b6e4b5c3c26e76e06ce26efa08ba1768e03fd2733fcc422bb0490
ARG OBSIDIAN_HEADLESS_VERSION=0.0.8
ARG QMD_VERSION=2.1.0
ARG PM2_VERSION=7.0.1
ARG AGENTMAIL_PYTHON_SDK_VERSION=0.5.0

# Install operator/debug tooling at build time. The running sandbox is policy-
# gated, lacks systemd, and should not rely on runtime package installs for
# core maintenance tools.
# hadolint ignore=DL3059,DL4006
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && printf '%s\n' 'deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        "gh=${GH_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) nvim_arch=x86_64; nvim_sha="${NEOVIM_X86_64_SHA256}" ;; \
        arm64) nvim_arch=arm64; nvim_sha="${NEOVIM_ARM64_SHA256}" ;; \
        *) echo "Unsupported Neovim architecture: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/nvim-linux-${nvim_arch}.tar.gz" \
        -o /tmp/nvim-linux.tar.gz \
    && printf '%s  %s\n' "$nvim_sha" /tmp/nvim-linux.tar.gz | sha256sum -c - \
    && mkdir -p /usr/local/lib/nvim \
    && tar -xzf /tmp/nvim-linux.tar.gz -C /usr/local/lib/nvim --strip-components=1 \
    && ln -sf /usr/local/lib/nvim/bin/nvim /usr/local/bin/nvim \
    && rm -f /tmp/nvim-linux.tar.gz \
    && gh --version \
    && nvim --version

# Copy built plugin and blueprint into the sandbox
COPY --from=builder /opt/nemoclaw/dist/ /opt/nemoclaw/dist/
COPY nemoclaw/openclaw.plugin.json /opt/nemoclaw/
COPY nemoclaw/package.json nemoclaw/package-lock.json /opt/nemoclaw/
COPY nemoclaw-blueprint/ /opt/nemoclaw-blueprint/

# Install runtime dependencies only (no devDependencies, no build step)
WORKDIR /opt/nemoclaw
RUN npm ci --omit=dev
RUN npm install -g --no-audit --no-fund --no-progress \
        "obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}" \
        "@tobilu/qmd@${QMD_VERSION}" \
        "pm2@${PM2_VERSION}" \
    && command -v ob >/dev/null \
    && command -v qmd >/dev/null \
    && command -v pm2 >/dev/null

# AgentMail baseline uses pinned host-side skill provisioning. Pre-install the
# Python SDK so the fresh sandbox does not depend on runtime pip network access.
RUN pip3 install --no-cache-dir --break-system-packages \
        "agentmail==${AGENTMAIL_PYTHON_SDK_VERSION}" \
    && python3 -c 'from agentmail import AgentMail; print(AgentMail.__name__)'

# Upgrade OpenClaw if the base image is stale.
#
# The GHCR base image (sandbox-base:latest) may lag behind the version pinned
# in Dockerfile.base. When that happens the fetch-guard patches below fail
# because the target functions don't exist in the older OpenClaw. Rather than
# silently skipping patches (leaving the sandbox unpatched), upgrade OpenClaw
# in-place so every build gets the version the patches expect.
#
# The minimum required version comes from nemoclaw-blueprint/blueprint.yaml
# (already COPYed to /opt/nemoclaw-blueprint/ above).
# hadolint ignore=DL3059,DL4006
RUN set -eu; \
    MIN_VER=$(grep -m 1 'min_openclaw_version' /opt/nemoclaw-blueprint/blueprint.yaml | awk '{print $2}' | tr -d '"'); \
    [ -n "$MIN_VER" ] || { echo "ERROR: Could not parse min_openclaw_version from blueprint.yaml" >&2; exit 1; }; \
    CUR_VER=$(openclaw --version 2>/dev/null | awk '{print $2}' || echo "0.0.0"); \
    if [ "$(printf '%s\n%s' "$MIN_VER" "$CUR_VER" | sort -V | head -n1)" = "$MIN_VER" ]; then \
        echo "INFO: OpenClaw $CUR_VER is current (>= $MIN_VER), no upgrade needed"; \
    else \
        echo "INFO: Base image has OpenClaw $CUR_VER, upgrading to $MIN_VER (minimum required)"; \
        # npm 10's atomic-move install can hit EROFS on overlayfs when the
        # prior install spans multiple image layers (e.g. openclaw was
        # baked into sandbox-base, then we upgrade on top here). Clearing
        # at the shell level first gives npm a clean slate and avoids the
        # rmdir failure inside npm's own install path.
        rm -rf /usr/local/lib/node_modules/openclaw /usr/local/bin/openclaw; \
        npm install -g --no-audit --no-fund --no-progress "openclaw@${MIN_VER}"; \
    fi; \
    # OpenClaw intentionally does not let the live gateway self-repair bundled \
    # channel dependencies in this managed image. Install Telegram runtime deps \
    # at build time so doctor/channel loading can resolve grammy without \
    # runtime npm. Do not run bare `npm install --prefix "$telegram_dir"`: \
    # OpenClaw 2026.5.x extension manifests can include workspace:* dev deps, \
    # which npm rejects outside the upstream monorepo even with --omit=dev. \
    telegram_dir=/usr/local/lib/node_modules/openclaw/dist/extensions/telegram; \
    test -e "$telegram_dir/package.json"; \
    tmp_telegram_deps=/tmp/openclaw-telegram-runtime-deps; \
    rm -rf "$tmp_telegram_deps"; \
    mkdir -p "$tmp_telegram_deps"; \
    npm install --prefix "$tmp_telegram_deps" --omit=dev --ignore-scripts --no-audit --no-fund --no-progress \
        '@grammyjs/runner@^2.0.3' \
        '@grammyjs/transformer-throttler@^1.2.1' \
        'grammy@^1.42.0' \
        'typebox@1.1.37' \
        'undici@8.1.0'; \
    rm -rf "$telegram_dir/node_modules"; \
    cp -a "$tmp_telegram_deps/node_modules" "$telegram_dir/node_modules"; \
    rm -rf "$tmp_telegram_deps"; \
    test -e "$telegram_dir/node_modules/grammy/package.json"; \
    # Install enabled core/plugin extension runtime deps that OpenClaw's \
    # bundled extension manifests declare with workspace:* dev deps. Installing \
    # explicit runtime packages avoids npm resolving those monorepo-only specs. \
    xai_dir=/usr/local/lib/node_modules/openclaw/dist/extensions/xai; \
    memory_core_dir=/usr/local/lib/node_modules/openclaw/dist/extensions/memory-core; \
    test -e "$xai_dir/package.json"; \
    test -e "$memory_core_dir/package.json"; \
    tmp_xai_deps=/tmp/openclaw-xai-runtime-deps; \
    rm -rf "$tmp_xai_deps"; \
    mkdir -p "$tmp_xai_deps"; \
    npm install --prefix "$tmp_xai_deps" --omit=dev --ignore-scripts --no-audit --no-fund --no-progress \
        '@mariozechner/pi-ai@0.71.1' \
        'typebox@1.1.37'; \
    rm -rf "$xai_dir/node_modules"; \
    cp -a "$tmp_xai_deps/node_modules" "$xai_dir/node_modules"; \
    rm -rf "$tmp_xai_deps"; \
    test -e "$xai_dir/node_modules/@mariozechner/pi-ai/package.json"; \
    tmp_memory_core_deps=/tmp/openclaw-memory-core-runtime-deps; \
    rm -rf "$tmp_memory_core_deps"; \
    mkdir -p "$tmp_memory_core_deps"; \
    npm install --prefix "$tmp_memory_core_deps" --omit=dev --ignore-scripts --no-audit --no-fund --no-progress \
        'chokidar@^5.0.0' \
        'typebox@1.1.37'; \
    rm -rf "$memory_core_dir/node_modules"; \
    cp -a "$tmp_memory_core_deps/node_modules" "$memory_core_dir/node_modules"; \
    rm -rf "$tmp_memory_core_deps"; \
    test -e "$memory_core_dir/node_modules/chokidar/package.json"; \
    # Pre-install the codex-acp package so the embedded ACPx runtime can
    # call the local binary instead of `npx @zed-industries/codex-acp`.
    # The sandbox's L7 proxy denies @zed-industries/* package URLs
    # (403 policy_denied), and npm still refreshes registry metadata for
    # versioned npx package specs even when the package is globally installed.
    # Installing the binary at build time and configuring ACPx to use it
    # directly keeps TC-SBX-02 off the runtime npm path.
    npm install -g --no-audit --no-fund --no-progress \
        '@zed-industries/codex-acp@0.11.1'; \
    command -v codex-acp >/dev/null

# Patch OpenClaw media fetch for proxy-only sandbox (NVIDIA/NemoClaw#1755).
#
# NemoClaw forces all sandbox egress through the OpenShell L7 proxy
# (default 10.200.0.1:3128). Two layers of OpenClaw must be patched for
# Telegram/Discord/Slack media downloads to work in this environment:
#
# === Patch 1: redirect strict-mode export to trusted-env-proxy ===
# OpenClaw's media fetch path (fetch-ClF-ZgDC.js → fetchRemoteMedia) calls
# fetchWithSsrFGuard(withStrictGuardedFetchMode({...})) unconditionally.
# Strict mode does DNS-pinning + direct connect, which fails in the sandbox
# netns where only the proxy is reachable. Rewriting the fetch-guard module
# export so the strict alias maps to withTrustedEnvProxyGuardedFetchMode
# makes the existing callsite request proxy mode without touching callers.
# The export pattern `withStrictGuardedFetchMode as <letter>` is stable
# across versions while alias letters drift between minified bundles.
# Files that define withStrictGuardedFetchMode locally without an export
# (e.g. mattermost.js) keep their original strict behavior.
#
# === Patch 2: env-gated bypass for assertExplicitProxyAllowed ===
# OpenClaw 2026.4.2 added assertExplicitProxyAllowed() in fetch-guard,
# which validates the explicit proxy URL by passing the proxy hostname
# through resolvePinnedHostnameWithPolicy() with the *target's* SsrfPolicy.
# When the target uses hostnameAllowlist (Telegram media policy:
# `["api.telegram.org"]`), the proxy hostname (e.g. 10.200.0.1) gets
# rejected with "Blocked hostname (not in allowlist)". This is an upstream
# OpenClaw design flaw: a proxy is infrastructure, not a fetch target, and
# should not be filtered through the target's allowlist.
#
# Inject an early-return guarded by `process.env.OPENSHELL_SANDBOX === "1"`
# so the bypass only activates inside an OpenShell sandbox runtime, which
# is what NemoClaw deploys into. OpenShell injects this env var when it
# starts a sandbox pod; any consumer running the same openclaw bundle
# outside an OpenShell sandbox (bare-metal, another wrapper) does not have
# OPENSHELL_SANDBOX set and keeps the full upstream SSRF check. The L7
# proxy itself enforces per-endpoint network policy inside the sandbox,
# so the trust boundary for SSRF protection is unchanged.
#
# Image-level `ENV` does NOT work here: OpenShell controls the pod env at
# runtime and image ENV vars set by Dockerfile are stripped. OPENSHELL_SANDBOX
# is the only marker reliably present in the runtime.
#
# === Patch 6: treat inference.local as an OpenShell-managed endpoint ===
# OpenClaw 2026.5.7 scopes trusted web-search provider calls with a hostname
# allowlist for fake-IP DNS safety. That allowlist still flows through the
# generic .local private-hostname classifier, so NemoClaw's managed xAI
# web_search endpoint (https://inference.local/v1) fails with
# "Blocked hostname or private/internal/special-use IP address" before the
# request can reach OpenShell's policy-enforced proxy. Exempt only the exact
# OpenShell virtual hostname, only when OPENSHELL_SANDBOX is present.
#
# === Removal criteria ===
# Patch 1: drop when OpenClaw deprecates withStrictGuardedFetchMode or
#   when all media-fetch callsites unconditionally pass useEnvProxy.
# Patch 2: drop when OpenClaw fixes assertExplicitProxyAllowed to skip the
#   target hostname allowlist for the proxy hostname check (or exposes config
#   to disable the check).
# Patch 6: drop when OpenClaw exposes a provider-web-search SSRF policy seam or
#   otherwise treats operator-configured trusted endpoints such as
#   inference.local as scoped private/special-use hosts.
#
# SYNC WITH OPENCLAW: these patches grep for specific exports and function
# definitions in the compiled OpenClaw dist (withStrictGuardedFetchMode,
# assertExplicitProxyAllowed). If OpenClaw renames, removes, or restructures
# either symbol in a future release, the grep will fail and the build will
# abort. When bumping OPENCLAW_VERSION, verify both symbols still exist in
# the new dist and update the regex / sed replacement accordingly.
#
# Both patches fail-close: if grep finds no targets, the build aborts so
# the next maintainer reviewing an OPENCLAW_VERSION bump knows to revisit.
COPY scripts/rcf_patch.py /usr/local/lib/nemoclaw/rcf_patch.py
# hadolint ignore=SC2016,DL3059,DL4006
RUN set -eu; \
    OC_DIST=/usr/local/lib/node_modules/openclaw/dist; \
    # --- Patch 1: rewrite fetch-guard export --- \
    fg_export="$(grep -RIlE --include='*.js' 'export \{[^}]*withStrictGuardedFetchMode as [a-z]' "$OC_DIST")"; \
    test -n "$fg_export"; \
    for f in $fg_export; do \
        grep -q 'withTrustedEnvProxyGuardedFetchMode' "$f" || { echo "ERROR: $f missing withTrustedEnvProxyGuardedFetchMode"; exit 1; }; \
    done; \
    printf '%s\n' "$fg_export" | xargs sed -i -E 's|withStrictGuardedFetchMode as ([a-z])|withTrustedEnvProxyGuardedFetchMode as \1|g'; \
    if grep -REq --include='*.js' 'withStrictGuardedFetchMode as [a-z]' "$OC_DIST"; then echo "ERROR: Patch 1 left strict-mode export alias" >&2; exit 1; fi; \
    # --- Patch 2: neutralize assertExplicitProxyAllowed --- \
    fg_assert="$(grep -RIlE --include='*.js' 'async function assertExplicitProxyAllowed' "$OC_DIST")"; \
    test -n "$fg_assert"; \
    printf '%s\n' "$fg_assert" | xargs sed -i -E 's|(async function assertExplicitProxyAllowed\([^)]*\) \{)|\1 if (process.env.OPENSHELL_SANDBOX === "1") return; /* nemoclaw: env-gated bypass, see Dockerfile */ |'; \
    grep -REq --include='*.js' 'assertExplicitProxyAllowed\([^)]*\) \{ if \(process\.env\.OPENSHELL_SANDBOX === "1"\) return; /\* nemoclaw' "$OC_DIST"; \
    # --- Patch 3: follow symlinks in plugin-install path checks (#2203) --- \
    # OpenClaw's install-safe-path and install-package-dir reject symlinked \
    # directories via lstat. Changing lstat → stat in these two modules lets \
    # symlinks resolve; the real security gates (realpath + isPathInside \
    # containment) remain intact — a symlink escaping the base tree is still caught. \
    # Scoped to install-safe-path + install-package-dir only. \
    isp_file="$(grep -RIlE --include='*.js' 'const baseLstat = await fs\.lstat\(baseDir\)' "$OC_DIST/install-safe-path-"*.js)"; \
    test -n "$isp_file" || { echo "ERROR: install-safe-path baseLstat pattern not found" >&2; exit 1; }; \
    sed -i 's/const baseLstat = await fs\.lstat(baseDir)/const baseLstat = await fs.stat(baseDir)/' "$isp_file"; \
    if grep -q 'const baseLstat = await fs\.lstat(baseDir)' "$isp_file"; then echo "ERROR: Patch 3a (install-safe-path) left baseLstat lstat call" >&2; exit 1; fi; \
    ipd_file="$(grep -RIlE --include='*.js' 'assertInstallBaseStable' "$OC_DIST/install-package-dir-"*.js)"; \
    test -n "$ipd_file" || { echo "ERROR: install-package-dir assertInstallBaseStable not found" >&2; exit 1; }; \
    sed -i 's/const baseLstat = await fs\.lstat(params\.installBaseDir)/const baseLstat = await fs.stat(params.installBaseDir)/' "$ipd_file"; \
    sed -i 's/baseLstat\.isSymbolicLink()/false \/* nemoclaw: symlink check disabled, realpath guards containment *\//' "$ipd_file"; \
    if grep -q 'fs\.lstat(params\.installBaseDir)' "$ipd_file"; then echo "ERROR: Patch 3b (install-package-dir) left lstat in assertInstallBaseStable" >&2; exit 1; fi; \
    # --- Patch 4: graceful EACCES in replaceConfigFile for sandbox (#2254) --- \
    # Plugin install persists metadata via replaceConfigFile. In the sandbox, \
    # openclaw.json is immutable (444 root:root) by design.  OpenClaw 2026.4.24 \
    # restructured config writes: replaceConfigFile now first attempts a \
    # single-key include-file mutation (tryWriteSingleTopLevelIncludeMutation), \
    # falling back to writeConfigFile for the full config.  Both paths can hit \
    # EACCES in the read-only sandbox tree.  This patch wraps the entire \
    # write block in a try/catch that catches EACCES when OPENSHELL_SANDBOX=1 \
    # and emits a warning instead of crashing.  Plugins still load via \
    # auto-discovery from the extensions directory. \
    rcf_file="$(grep -RIlE --include='*.js' 'async function replaceConfigFile\(params\)' "$OC_DIST" | head -n 1)"; \
    test -n "$rcf_file" || { echo "ERROR: replaceConfigFile function not found in OpenClaw dist" >&2; exit 1; }; \
    python3 /usr/local/lib/nemoclaw/rcf_patch.py "$rcf_file"; \
    grep -REq --include='*.js' 'OPENSHELL_SANDBOX.*EACCES' "$rcf_file" || { echo "ERROR: Patch 4 (replaceConfigFile EACCES) not applied" >&2; exit 1; }; \
    # --- Patch 5: cron local-provider preflight must use proxy DNS (#2484) --- \
    # Isolated cron jobs preflight local providers before agent execution. \
    # Without trusted_env_proxy mode, the probe resolves inference.local \
    # directly inside the sandbox and skips jobs with getaddrinfo EAI_AGAIN. \
    # OpenShell owns inference.local behind the sandbox proxy, so cron must use \
    # the same proxy-aware fetch path as normal agent inference. \
    mp_file="$(grep -RIlE --include='model-preflight.runtime-*.js' 'auditContext: "cron-model-provider-preflight"' "$OC_DIST")"; \
    test -n "$mp_file" || { echo "ERROR: cron model preflight runtime not found" >&2; exit 1; }; \
    for f in $mp_file; do \
        grep -q 'mode: "trusted_env_proxy"' "$f" || sed -i 's/auditContext: "cron-model-provider-preflight"/auditContext: "cron-model-provider-preflight",\n\t\tmode: "trusted_env_proxy"/' "$f"; \
        grep -q 'mode: "trusted_env_proxy"' "$f" || { echo "ERROR: Patch 5 (cron trusted_env_proxy) not applied to $f" >&2; exit 1; }; \
    done; \
    # --- Patch 6: allow OpenShell-managed inference.local trusted endpoint --- \
    ssrf_file="$(grep -RIlE --include='ssrf-*.js' 'function isBlockedHostnameNormalized\(normalized\)' "$OC_DIST")"; \
    test -n "$ssrf_file" || { echo "ERROR: SSRF hostname classifier not found" >&2; exit 1; }; \
    printf '%s\n' "$ssrf_file" | xargs sed -i -E 's|(function isBlockedHostnameNormalized\(normalized\) \{)|\1 if (process.env.OPENSHELL_SANDBOX === "1" \&\& normalized === "inference.local") return false; /* nemoclaw: OpenShell managed inference route, see Dockerfile */ |'; \
    grep -REq --include='ssrf-*.js' 'normalized === "inference\.local"\) return false; /\* nemoclaw: OpenShell managed inference route' "$OC_DIST" || { echo "ERROR: Patch 6 (inference.local SSRF exception) not applied" >&2; exit 1; }

# Set up blueprint for local resolution.
# Blueprints are immutable at runtime; DAC protection (root ownership) is applied
# later since /sandbox/.nemoclaw is Landlock read_write for plugin state (#804).
RUN mkdir -p /sandbox/.nemoclaw/blueprints/0.1.0 \
    && cp -r /opt/nemoclaw-blueprint/* /sandbox/.nemoclaw/blueprints/0.1.0/

# Copy startup script and shared sandbox initialisation library
COPY scripts/lib/sandbox-init.sh /usr/local/lib/nemoclaw/sandbox-init.sh
COPY scripts/nemoclaw-start.sh /usr/local/bin/nemoclaw-start
# Copy NODE_OPTIONS preload modules to a Landlock-accessible path. OpenShell ≥0.0.36
# blocks /opt/nemoclaw-blueprint/ from non-root users, but the entrypoint
# needs to read these files to install runtime preloads under /tmp.
COPY nemoclaw-blueprint/scripts/*.js /usr/local/lib/nemoclaw/preloads/
COPY scripts/codex-acp-wrapper.sh /usr/local/bin/nemoclaw-codex-acp
COPY scripts/generate-openclaw-config.py /usr/local/lib/nemoclaw/generate-openclaw-config.py
COPY nemoclaw-blueprint/openclaw-plugins/ /usr/local/share/nemoclaw/openclaw-plugins/
RUN chmod 755 /usr/local/bin/nemoclaw-start /usr/local/bin/nemoclaw-codex-acp \
        /usr/local/lib/nemoclaw/sandbox-init.sh \
        /usr/local/lib/nemoclaw/generate-openclaw-config.py \
    && if [ -d /usr/local/lib/nemoclaw/preloads ]; then find /usr/local/lib/nemoclaw/preloads -type f -name '*.js' -exec chmod 644 {} +; fi \
    && if [ -f /usr/local/lib/nemoclaw/ws-proxy-fix.js ]; then chmod 644 /usr/local/lib/nemoclaw/ws-proxy-fix.js; fi \
    && chmod 755 /usr/local/share/nemoclaw \
        /usr/local/share/nemoclaw/openclaw-plugins \
    && find /usr/local/share/nemoclaw/openclaw-plugins -type d -exec chmod 755 {} + \
    && find /usr/local/share/nemoclaw/openclaw-plugins -type f -exec chmod 644 {} +

# Build args for config that varies per deployment.
# nemoclaw onboard passes these at image build time.
ARG NEMOCLAW_MODEL=nvidia/nemotron-3-super-120b-a12b
ARG NEMOCLAW_PROVIDER_KEY=inference
ARG NEMOCLAW_PRIMARY_MODEL_REF=inference/nvidia/nemotron-3-super-120b-a12b
# Default dashboard port 18789 — override at runtime via NEMOCLAW_DASHBOARD_PORT.
ARG CHAT_UI_URL=http://127.0.0.1:18789
ARG NEMOCLAW_INFERENCE_BASE_URL=https://inference.local/v1
ARG NEMOCLAW_INFERENCE_API=openai-completions
ARG NEMOCLAW_CONTEXT_WINDOW=131072
ARG NEMOCLAW_MAX_TOKENS=4096
ARG NEMOCLAW_REASONING=false
# Comma-separated list of input modalities accepted by the primary model
# (e.g. "text" or "text,image" for vision-capable models). OpenClaw's
# model schema currently accepts "text" and "image". See #2421.
ARG NEMOCLAW_INFERENCE_INPUTS=text
# Per-request inference timeout (seconds) baked into agents.defaults.timeoutSeconds.
# Increase for slow local inference (e.g., CPU Ollama). openclaw.json is
# immutable at runtime (Landlock read-only), so this can only be changed by
# rebuilding via `nemoclaw onboard`. Ref: issue #2281
ARG NEMOCLAW_AGENT_TIMEOUT=600
ARG NEMOCLAW_INFERENCE_COMPAT_B64=e30=
# Base64-encoded JSON list of messaging channel names to pre-configure
# (e.g. ["discord","telegram"]). Channels are added with placeholder tokens
# so the L7 proxy can rewrite them at egress. Default: empty list.
ARG NEMOCLAW_MESSAGING_CHANNELS_B64=W10=
# Base64-encoded JSON map of channel→allowed sender IDs for DM allowlisting
# (e.g. {"telegram":["123456789"]}). Channels with IDs get dmPolicy=allowlist;
# channels without IDs keep the OpenClaw default (pairing). Default: empty map.
ARG NEMOCLAW_MESSAGING_ALLOWED_IDS_B64=e30=
# Base64-encoded JSON map of Discord guild configs keyed by server ID
# (e.g. {"1234567890":{"requireMention":true,"users":["555"]}}).
# Used to enable guild-channel responses for native Discord. Default: empty map.
ARG NEMOCLAW_DISCORD_GUILDS_B64=e30=
# Base64-encoded JSON Telegram config (e.g. {"requireMention":true}).
# When requireMention is true, Telegram groups get groups: {"*": {"requireMention": true}}
# with groupPolicy: open. See #1737, #3022. Default: empty map.
ARG NEMOCLAW_TELEGRAM_CONFIG_B64=e30=
# Set to "1" to force-disable device-pairing auth. Also auto-disabled when
# CHAT_UI_URL is a non-loopback address (Brev Launchable, remote deployments)
# since terminal-based pairing is impossible in those contexts.
# Default: "0" (device auth enabled for local deployments — secure by default).
ARG NEMOCLAW_DISABLE_DEVICE_AUTH=0
# Unique per build — busts the Docker cache for the token-injection layer
# so each image gets a fresh gateway auth token.
# Pass --build-arg NEMOCLAW_BUILD_ID=$(date +%s) to bust the cache.
ARG NEMOCLAW_BUILD_ID=default
# Sandbox egress proxy host/port. Defaults match the OpenShell-injected
# gateway (10.200.0.1:3128). Operators on non-default networks can override
# at sandbox creation time by exporting NEMOCLAW_PROXY_HOST / NEMOCLAW_PROXY_PORT
# before running `nemoclaw onboard`. See #1409.
ARG NEMOCLAW_PROXY_HOST=10.200.0.1
ARG NEMOCLAW_PROXY_PORT=3128
# Non-secret flag: set to "1" when the user configured Brave Search during
# onboard. Controls whether the web search block is written to openclaw.json.
# The actual API key is injected at runtime via openshell:resolve:env, never
# baked into the image.
ARG NEMOCLAW_WEB_SEARCH_ENABLED=0

# SECURITY: Promote build-args to env vars so the Python script reads them
# via os.environ, never via string interpolation into Python source code.
# Direct ARG interpolation into python3 -c is a code injection vector (C-2).
ENV NEMOCLAW_MODEL=${NEMOCLAW_MODEL} \
    NEMOCLAW_PROVIDER_KEY=${NEMOCLAW_PROVIDER_KEY} \
    NEMOCLAW_PRIMARY_MODEL_REF=${NEMOCLAW_PRIMARY_MODEL_REF} \
    CHAT_UI_URL=${CHAT_UI_URL} \
    NEMOCLAW_INFERENCE_BASE_URL=${NEMOCLAW_INFERENCE_BASE_URL} \
    NEMOCLAW_INFERENCE_API=${NEMOCLAW_INFERENCE_API} \
    NEMOCLAW_CONTEXT_WINDOW=${NEMOCLAW_CONTEXT_WINDOW} \
    NEMOCLAW_MAX_TOKENS=${NEMOCLAW_MAX_TOKENS} \
    NEMOCLAW_REASONING=${NEMOCLAW_REASONING} \
    NEMOCLAW_INFERENCE_INPUTS=${NEMOCLAW_INFERENCE_INPUTS} \
    NEMOCLAW_AGENT_TIMEOUT=${NEMOCLAW_AGENT_TIMEOUT} \
    NEMOCLAW_INFERENCE_COMPAT_B64=${NEMOCLAW_INFERENCE_COMPAT_B64} \
    NEMOCLAW_MESSAGING_CHANNELS_B64=${NEMOCLAW_MESSAGING_CHANNELS_B64} \
    NEMOCLAW_MESSAGING_ALLOWED_IDS_B64=${NEMOCLAW_MESSAGING_ALLOWED_IDS_B64} \
    NEMOCLAW_DISCORD_GUILDS_B64=${NEMOCLAW_DISCORD_GUILDS_B64} \
    NEMOCLAW_TELEGRAM_CONFIG_B64=${NEMOCLAW_TELEGRAM_CONFIG_B64} \
    NEMOCLAW_DISABLE_DEVICE_AUTH=${NEMOCLAW_DISABLE_DEVICE_AUTH} \
    NEMOCLAW_PROXY_HOST=${NEMOCLAW_PROXY_HOST} \
    NEMOCLAW_PROXY_PORT=${NEMOCLAW_PROXY_PORT} \
    NEMOCLAW_WEB_SEARCH_ENABLED=${NEMOCLAW_WEB_SEARCH_ENABLED}

WORKDIR /sandbox
USER sandbox

# Write openclaw.json with gateway config but WITHOUT the real auth token.
# The gateway auth token is generated at container startup by the entrypoint
# and passed via OPENCLAW_GATEWAY_TOKEN env var only to the gateway process
# (running as 'gateway' user). The token file location depends on startup mode:
#   Root mode:     /run/nemoclaw/gateway-token (gateway:gateway 0400)
#   Non-root mode: $XDG_RUNTIME_DIR/nemoclaw/gateway-token (sandbox:sandbox 0400)
# See: scripts/nemoclaw-start.sh generate_gateway_token()
#
# Config is mutable by default (group-writable sandbox:sandbox). Immutability
# is opt-in via `shields up` (DAC 444 root:root + chattr +i).
# Build args (NEMOCLAW_MODEL, CHAT_UI_URL) customize per deployment.
#
# Temporary workaround for NemoClaw#1738: the OpenClaw Discord extension's
# gateway uses `ws` (via @buape/carbon), which ignores HTTPS_PROXY/HTTP_PROXY
# env vars and opens a direct TCP socket to gateway.discord.gg. Sandbox netns
# blocks direct egress, so the WSS handshake never reaches Discord and the
# bot loops on close-code 1006. Baking `accounts.default.proxy` into
# openclaw.json feeds DiscordAccountConfig.proxy, which the gateway plugin
# threads through to the `ws` `agent` option, routing the upgrade through
# the OpenShell proxy. Mirror of the Telegram treatment immediately below.
# Remove once OpenClaw lands an env-var-honouring fix for the Discord
# gateway equivalent to openclaw/openclaw#62878 (Slack Socket Mode).
# Generate openclaw.json from environment variables. Config generation logic
# lives in scripts/generate-openclaw-config.py — see that file for the full
# list of env vars and derivation rules.
RUN python3 /usr/local/lib/nemoclaw/generate-openclaw-config.py

# Install NemoClaw plugin into OpenClaw. Prune non-runtime metadata from
# staged bundled plugin dependencies before this layer is committed; deleting
# it in a later layer would not reduce the OCI image imported by k3s.
RUN (openclaw doctor --fix > /dev/null 2>&1 || true) \
    && (openclaw plugins install /opt/nemoclaw > /dev/null 2>&1 || true) \
    && if [ -d /sandbox/.openclaw/plugin-runtime-deps ]; then \
        find /sandbox/.openclaw/plugin-runtime-deps -type f \( \
            -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o \
            -name '*.map' -o -name '*.tsbuildinfo' \
        \) -delete; \
        find /sandbox/.openclaw/plugin-runtime-deps -type d \( \
            -name __tests__ -o -name test -o -name tests -o -name docs -o \
            -name examples \
        \) -prune -exec rm -rf {} +; \
    fi

# SECURITY: Clear any gateway auth token that openclaw doctor/plugins may have
# auto-generated. The real token is created at container startup by the
# entrypoint (generate_gateway_token) and never stored in openclaw.json.
RUN python3 -c "\
import json, os; \
path = os.path.expanduser('~/.openclaw/openclaw.json'); \
cfg = json.load(open(path)); \
cfg.setdefault('gateway', {}).setdefault('auth', {})['token'] = ''; \
json.dump(cfg, open(path, 'w'), indent=2); \
os.chmod(path, 0o600)"

# Flatten stale published base images that still contain the old
# .openclaw-data symlink bridge. OpenShell starts the sandbox as the sandbox
# user, so runtime migration cannot rely on root privileges inside the pod.
# Doing this in the image build guarantees new PR images have only the unified
# .openclaw layout even when sandbox-base:latest has not been rebuilt yet.
# hadolint ignore=DL3002
USER root
# hadolint ignore=DL4006
RUN set -eu; \
    config_dir=/sandbox/.openclaw; \
    data_dir=/sandbox/.openclaw-data; \
    mkdir -p "$config_dir"; \
    if [ -L "$data_dir" ]; then \
        echo "ERROR: refusing legacy layout cleanup because $data_dir is a symlink" >&2; \
        exit 1; \
    fi; \
    if [ -d "$data_dir" ]; then \
        for entry in "$data_dir"/*; do \
            [ -e "$entry" ] || [ -L "$entry" ] || continue; \
            if [ -L "$entry" ]; then \
                echo "ERROR: refusing legacy layout cleanup because $entry is a symlink" >&2; \
                exit 1; \
            fi; \
            name="$(basename "$entry")"; \
            target="$config_dir/$name"; \
            if [ -L "$target" ]; then \
                rm -f "$target"; \
            fi; \
            if [ -d "$entry" ]; then \
                mkdir -p "$target"; \
                cp -a "$entry"/. "$target"/; \
            elif [ ! -e "$target" ]; then \
                cp -a "$entry" "$target"; \
            fi; \
        done; \
        data_real="$(readlink -f "$data_dir" 2>/dev/null || printf '%s' "$data_dir")"; \
        while :; do \
            replaced_marker="$(mktemp)"; \
            rm -f "$replaced_marker"; \
            find "$config_dir" -type l -print | while IFS= read -r link; do \
                raw_target="$(readlink "$link" 2>/dev/null || true)"; \
                resolved_target="$(readlink -f "$link" 2>/dev/null || true)"; \
                legacy_target=0; \
                case "$raw_target" in "$data_real"/* | "$data_dir"/*) legacy_target=1 ;; esac; \
                case "$resolved_target" in "$data_real"/* | "$data_dir"/*) legacy_target=1 ;; esac; \
                if [ "$legacy_target" -eq 1 ]; then \
                    copy_target="$resolved_target"; \
                    if [ -z "$copy_target" ] || { [ ! -e "$copy_target" ] && [ ! -L "$copy_target" ]; }; then \
                        copy_target="$raw_target"; \
                    fi; \
                    if [ -d "$copy_target" ] && [ ! -L "$copy_target" ]; then \
                            rm -f "$link"; \
                            mkdir -p "$link"; \
                            cp -a "$copy_target"/. "$link"/; \
                    elif [ -e "$copy_target" ] || [ -L "$copy_target" ]; then \
                            rm -f "$link"; \
                            cp -a "$copy_target" "$link"; \
                    else \
                        echo "ERROR: legacy symlink target missing: $link -> ${raw_target:-$resolved_target}" >&2; \
                        exit 1; \
                    fi; \
                    : > "$replaced_marker"; \
                fi; \
            done; \
            if [ ! -e "$replaced_marker" ]; then \
                rm -f "$replaced_marker"; \
                break; \
            fi; \
            rm -f "$replaced_marker"; \
        done; \
        rm -rf "$data_dir"; \
    fi; \
    mkdir -p "$config_dir/agents/main/agent" \
        "$config_dir/extensions" \
        "$config_dir/workspace" \
        "$config_dir/skills" \
        "$config_dir/hooks" \
        "$config_dir/identity" \
        "$config_dir/devices" \
        "$config_dir/canvas" \
        "$config_dir/cron" \
        "$config_dir/memory" \
        "$config_dir/logs" \
        "$config_dir/credentials" \
        "$config_dir/flows" \
        "$config_dir/sandbox" \
        "$config_dir/telegram" \
        "$config_dir/media" \
        "$config_dir/plugin-runtime-deps"; \
    touch "$config_dir/update-check.json" "$config_dir/exec-approvals.json"; \
    if [ -e "$data_dir" ] || [ -L "$data_dir" ]; then \
        echo "ERROR: legacy data dir still exists after cleanup: $data_dir" >&2; \
        exit 1; \
    fi; \
    data_real="$(readlink -f "$data_dir" 2>/dev/null || printf '%s' "$data_dir")"; \
    find "$config_dir" -type l -print | while IFS= read -r link; do \
        raw_target="$(readlink "$link" 2>/dev/null || true)"; \
        resolved_target="$(readlink -f "$link" 2>/dev/null || true)"; \
        case "$raw_target" in \
            "$data_real"/* | "$data_dir"/*) \
                echo "ERROR: legacy symlink remains after cleanup: $link -> $raw_target" >&2; \
                exit 1; \
                ;; \
        esac; \
        case "$resolved_target" in \
            "$data_real"/* | "$data_dir"/*) \
                echo "ERROR: legacy symlink remains after cleanup: $link -> $resolved_target" >&2; \
                exit 1; \
                ;; \
        esac; \
    done; \
    rm -rf /root/.npm /sandbox/.npm

# Stale-base fallback for the gateway-in-sandbox-group setup (#2681).
# Newer base images already add the gateway user to the sandbox group, but
# the derived image must remain build-clean against older sandbox-base:latest
# tags too. The `id -nG` check makes this idempotent.
# hadolint ignore=DL4006
RUN if id gateway >/dev/null 2>&1 && id sandbox >/dev/null 2>&1; then \
        if ! id -nG gateway | tr ' ' '\n' | grep -qx sandbox; then \
            usermod -aG sandbox gateway; \
        fi; \
    fi

# Keep the image readable to the root entrypoint after capabilities are
# dropped. OpenShell starts the runtime as the sandbox user; the entrypoint
# and onboard flow normalize the mutable-default group-writable permissions.
# Shields-up applies 444 root:root + chattr +i on top.
#
# `chmod g+w` + setgid (chmod g+s on dirs) on the mutable config tree means
# both `sandbox` and `gateway` (now a member of the sandbox group) can write
# to OpenClaw config/state in default mode. New files created in setgid
# directories inherit group=sandbox regardless of which UID created them,
# so OpenClaw's mutateConfigFile path (control-UI toggles) writes succeed
# without needing an EACCES-swallow patch (#2681 supersedes #2693).
RUN chown -R sandbox:sandbox /sandbox/.openclaw \
    && chmod -R g+rwX,o-rwx /sandbox/.openclaw \
    && find /sandbox/.openclaw -type d -exec chmod g+s {} + \
    && chmod 2770 /sandbox/.openclaw \
    && chmod 660 /sandbox/.openclaw/openclaw.json

# System-wide proxy hooks for shells where ~/.bashrc / ~/.profile aren't
# sourced (e.g. `bash -ic` / `bash -lc` invoked under a different user or
# without HOME=/sandbox). Defined in Dockerfile.base; replayed here so the
# fix applies before the GHCR base image catches up. Idempotent — `mv` of
# a freshly-rebuilt /etc/bash.bashrc is harmless once the base layer
# already includes the prepended hook (the cat | mv block just rewrites
# with the same first line).
# Ref: https://github.com/NVIDIA/NemoClaw/issues/2704
# hadolint ignore=SC2028,DL4006
RUN if ! grep -q "/tmp/nemoclaw-proxy-env.sh" /etc/profile.d/nemoclaw-proxy.sh 2>/dev/null; then \
        printf '%s\n' \
            '# NemoClaw runtime proxy config — see /tmp/nemoclaw-proxy-env.sh (#2704)' \
            '[ -f /tmp/nemoclaw-proxy-env.sh ] && . /tmp/nemoclaw-proxy-env.sh' \
            > /etc/profile.d/nemoclaw-proxy.sh \
        && chmod 444 /etc/profile.d/nemoclaw-proxy.sh; \
    fi \
    && if ! head -2 /etc/bash.bashrc | grep -q "/tmp/nemoclaw-proxy-env.sh"; then \
        chmod 644 /etc/bash.bashrc 2>/dev/null || true; \
        { printf '%s\n' \
              '# NemoClaw runtime proxy config — see /tmp/nemoclaw-proxy-env.sh (#2704)' \
              '[ -f /tmp/nemoclaw-proxy-env.sh ] && . /tmp/nemoclaw-proxy-env.sh' \
              ''; \
          cat /etc/bash.bashrc; \
        } > /etc/bash.bashrc.new \
        && mv /etc/bash.bashrc.new /etc/bash.bashrc \
        && chmod 444 /etc/bash.bashrc; \
    fi

# Pin config hash at build time so the entrypoint can verify integrity.
RUN sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash \
    && chmod 660 /sandbox/.openclaw/.config-hash \
    && chown sandbox:sandbox /sandbox/.openclaw/.config-hash

# DAC-protect .nemoclaw directory: /sandbox/.nemoclaw is Landlock read_write
# (for plugin state/config), but the parent and blueprints are immutable at
# runtime. Root ownership on the parent prevents the agent from renaming or
# replacing the root-owned blueprints directory. Only state/, migration/,
# snapshots/, and config.json are sandbox-owned for runtime writes.
# Sticky bit (1755): OpenShell's prepare_filesystem() chowns read_write paths
# to run_as_user at sandbox start, flipping this dir to sandbox:sandbox.
# The sticky bit survives the chown and prevents the sandbox user from
# renaming or deleting root-owned entries (blueprints/).
# Ref: https://github.com/NVIDIA/NemoClaw/issues/804
# Ref: https://github.com/NVIDIA/NemoClaw/issues/1607
RUN chown root:root /sandbox/.nemoclaw \
    && chmod 1755 /sandbox/.nemoclaw \
    && chown -R root:root /sandbox/.nemoclaw/blueprints \
    && chmod -R 755 /sandbox/.nemoclaw/blueprints \
    && mkdir -p /sandbox/.nemoclaw/state /sandbox/.nemoclaw/migration /sandbox/.nemoclaw/snapshots /sandbox/.nemoclaw/staging \
    && chown sandbox:sandbox /sandbox/.nemoclaw/state /sandbox/.nemoclaw/migration /sandbox/.nemoclaw/snapshots /sandbox/.nemoclaw/staging \
    && touch /sandbox/.nemoclaw/config.json \
    && chown sandbox:sandbox /sandbox/.nemoclaw/config.json

# Entrypoint runs as root to start the gateway as the gateway user,
# then drops to sandbox for agent commands. See nemoclaw-start.sh.
ENTRYPOINT ["/usr/local/bin/nemoclaw-start"]
CMD ["/bin/bash"]
