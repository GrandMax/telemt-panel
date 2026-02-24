# ==========================
# Stage 1: Build
# ==========================
# Полный bookworm: уже есть pkg-config, gcc — без apt-get (обход GPG-проблем на части хостов)
FROM rust:1.93.1-bookworm AS builder

WORKDIR /build

# Один полный сбор без dummy-build: для arm64 (QEMU) два прохода cargo занимают часы
# Сначала копируем манифест, lock-файл и исходники (без лишних файлов из репозитория).
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN rustc --version && cargo build --release && strip target/release/telemt

# ==========================
# Stage 2: Runtime
# ==========================
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /usr/sbin/nologin telemt

WORKDIR /app

COPY --from=builder /build/target/release/telemt /app/telemt

RUN chown -R telemt:telemt /app
USER telemt

EXPOSE 443
EXPOSE 9090

ENTRYPOINT ["/app/telemt"]
CMD ["config.toml"]