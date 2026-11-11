# Build context is the repo root:  docker build -f api-service-go/Dockerfile .
FROM golang:1-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest \
 && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
WORKDIR /src
COPY proto/products.proto proto/products.proto
COPY api-service-go/go.mod api-service-go/main.go ./
# generates gen/productspb/products.pb.go and products_grpc.pb.go
RUN protoc -I proto \
      --go_out=. --go_opt=module=api-service \
      --go-grpc_out=. --go-grpc_opt=module=api-service \
      proto/products.proto
# resolves grpc-go / protobuf versions matching the generated code
RUN go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/api-service .

FROM debian:bookworm-slim
COPY --from=build /out/api-service /app/api-service
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/app/api-service"]
