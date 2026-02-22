# ==========================
# Stage 1: Build
# ==========================
# https://hub.docker.com/layers/library/rust/1.93.1-slim-bookworm
FROM rust:1.93.1-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Один полный сбор без dummy-build: для arm64 (QEMU) два прохода cargo занимают часы
COPY . .
RUN rustc --version && cargo build --release && strip target/release/telemt

# ==========================
# Stage 2: Runtime
# ==========================
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /usr/sbin/nologin telemt

WORKDIR /app

COPY --from=builder /build/target/release/telemt /app/telemt
COPY config.toml /app/config.toml

RUN chown -R telemt:telemt /app
USER telemt

EXPOSE 443
EXPOSE 9090

ENTRYPOINT ["/app/telemt"]
CMD ["config.toml"]