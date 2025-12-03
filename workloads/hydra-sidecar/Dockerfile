# Multi-arch build for hydra-sidecar
# Default: debug-nonroot (with busybox shell)
# Override with --build-arg DISTROLESS_VARIANT=nonroot for hardened production

# ARG must be declared before FROM that uses it
ARG DISTROLESS_VARIANT=debug-nonroot

FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS builder

# Install git for go mod download (some dependencies need it)
RUN apk add --no-cache git

ARG TARGETOS
ARG TARGETARCH

WORKDIR /app

# Copy go mod files first for better caching
COPY go.mod go.sum* ./
RUN go mod download

# Copy source files
COPY *.go ./

# Build the binary
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -o hydra-sidecar .

# Final stage - distroless
# debug-nonroot includes busybox shell for debugging
# nonroot is the hardened variant without shell
ARG DISTROLESS_VARIANT
FROM gcr.io/distroless/static:${DISTROLESS_VARIANT}

COPY --from=builder /app/hydra-sidecar /hydra-sidecar

# Run as non-root user (distroless nonroot user is 65532)
USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/hydra-sidecar"]
