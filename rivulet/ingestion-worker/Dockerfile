# syntax=docker/dockerfile:1.7

# --- Stage 1: Build ---
FROM docker.io/library/golang:1.27.1-alpine3.24@sha256:4cb7ac979db5fcc41cae44b2227ba5ab8a51e8807f40d9ba4dee20a0ad960b5b AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG TARGETOS=linux
ARG TARGETARCH
ARG GIT_SHA=unknown

RUN CGO_ENABLED=0 \
    GOOS="${TARGETOS}" \
    GOARCH="${TARGETARCH}" \
    go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /worker \
    ./cmd/worker

# --- Stage 2: Runtime ---
FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3

WORKDIR /app

COPY --from=builder /worker /app/worker

# Inject build metadata so the service self-reports its version in telemetry
ARG GIT_SHA=unknown
ENV GIT_VERSION=${GIT_SHA}

# Required for SAST pass
USER nonroot:nonroot

EXPOSE 8080 8081

ENTRYPOINT ["/app/worker"]
