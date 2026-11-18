# Drafft.ink (fork) — one image: the web build + the collaboration server.
#
# The server (`drafftink-headless serve`) serves the web client and the /ws
# collaboration socket from one origin, so this image is the whole deployment
# (docs/server.md). It speaks plain HTTP: put a TLS-terminating reverse proxy
# in front of it for wss://, and keep the published port on loopback until an
# access gate is in front (see docker-compose.yml).
#
# Build:  docker compose build        (or: docker build -t drafftink .)
# The web build is the expensive part: two wasm modules (WebGPU + WebGL2
# fallback) at the release-wasm profile, exactly as scripts/build-web.sh
# builds them for a release. Expect several minutes on a small machine.
#
# DRAFFTINK_COMMIT (build arg): the commit shown in the About dialog. The
# build context has no .git (see .dockerignore), so pass the short hash when
# it matters:  docker build --build-arg DRAFFTINK_COMMIT=$(git rev-parse --short=10 HEAD) .
# Empty (the default) records "unknown", the same as a tarball build upstream.

# ---------------------------------------------------------------- builder
FROM rust:bookworm AS builder

# The pinned toolchain of rust-toolchain.toml. The rust image ships rustup, so
# install the exact channel instead of taking the image's default stable.
RUN rustup toolchain install 1.97.1 --profile minimal \
    && rustup target add --toolchain 1.97.1 wasm32-unknown-unknown

# Tools scripts/build-web.sh needs beyond the toolchain:
#   brotli  — writes the .br copies the server serves (and the size table)
#   curl/ca-certificates — fetch the two pinned tool downloads below
# gzip, sha256sum, stat are in the base image. A C compiler for the bundled
# SQLite (server feature `sqlite`) is in the rust image already.
RUN apt-get update \
    && apt-get install -y --no-install-recommends brotli curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# wasm-bindgen CLI: the version must equal the crate pin in Cargo.toml
# (0.2.130), or the web build refuses to run. Prebuilt binary, as in
# .github/workflows/deploy-web.yml (which installs the same version).
ARG WASM_BINDGEN_VERSION=0.2.130
RUN curl -fsSL "https://github.com/wasm-bindgen/wasm-bindgen/releases/download/${WASM_BINDGEN_VERSION}/wasm-bindgen-${WASM_BINDGEN_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar -xz -C /tmp \
    && install -m 0755 "/tmp/wasm-bindgen-${WASM_BINDGEN_VERSION}-x86_64-unknown-linux-musl/wasm-bindgen" /usr/local/bin/wasm-bindgen \
    && wasm-bindgen --version

# wasm-opt: binaryen 133, the version the release builds are measured with.
ARG BINARYEN_VERSION=133
RUN curl -fsSL "https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/binaryen-version_${BINARYEN_VERSION}-x86_64-linux.tar.gz" \
        | tar -xz -C /opt \
    && ln -s "/opt/binaryen-version_${BINARYEN_VERSION}/bin/wasm-opt" /usr/local/bin/wasm-opt \
    && wasm-opt --version

WORKDIR /src
COPY . .

ARG DRAFFTINK_COMMIT=""
ENV DRAFFTINK_COMMIT=${DRAFFTINK_COMMIT}

# cargo fetch first: scripts/build-web.sh reads the egui fonts out of the
# registry cache, so the registry must be populated before it runs.
RUN cargo fetch --locked \
    && scripts/build-web.sh \
    && cargo build --release --locked -p drafftink-headless --features sqlite,s3 \
    && install -m 0755 target/release/drafftink-headless /out-drafftink-headless

# ---------------------------------------------------------------- runtime
FROM debian:bookworm-slim AS runtime

# curl is only for the healthcheck; ca-certificates for the S3 store's TLS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home-dir /app --shell /usr/sbin/nologin drafftink \
    && mkdir -p /data && chown drafftink:drafftink /data

WORKDIR /app
COPY --from=builder /out-drafftink-headless /usr/local/bin/drafftink-headless
COPY --from=builder /src/dist /app/web-dist

# AGPL-3.0 section 13: the source offer of a hosted, modified build must point
# at this fork. The compiled-in default already does (it comes from the
# workspace repository); the env var states it at the deployment, where it can
# be changed without a rebuild.
ENV DRAFFTINK_SOURCE_URL=https://github.com/noahmchugh/drafft-ink

USER drafftink
EXPOSE 3030
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3030/health || exit 1

ENTRYPOINT ["drafftink-headless", "serve"]
# --bind 0.0.0.0 is the container's own network only: docker-compose.yml
# publishes the port on the host's loopback. Storage is SQLite in the /data
# volume (snapshot + update log, one file, see docs/server.md).
CMD ["--web-dir", "/app/web-dist", "--bind", "0.0.0.0:3030", \
     "--storage", "sqlite", "--data-dir", "/data"]
