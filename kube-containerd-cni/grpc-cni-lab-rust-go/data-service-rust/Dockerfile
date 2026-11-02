# Build context is the repo root:  docker build -f data-service-rust/Dockerfile .
FROM rust:1-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY proto/products.proto proto/products.proto
COPY data-service-rust/Cargo.toml data-service-rust/build.rs ./
COPY data-service-rust/src src
RUN cargo build --release

# Same Debian release as the builder so glibc matches
FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /src/target/release/data-service /app/data-service
COPY data-service-rust/seed.json /app/seed.json
USER 65534:65534
EXPOSE 50051
ENTRYPOINT ["/app/data-service"]
