# --- Stage 1: Build the Go binary ---

FROM golang:1.24-alpine AS builder
WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY *.go ./
COPY web/ ./web/

RUN CGO_ENABLED=0 GOOS=linux go build \
    -a -installsuffix cgo -o thinkific-client .

# --- Stage 2: Minimal runtime image ---

FROM alpine:3.21
RUN apk --no-cache add ca-certificates curl

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app
COPY --from=builder /app/thinkific-client .

RUN chown -R appuser:appgroup /app
USER appuser

# If you change client_port in config.yaml, update this to match
EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8081/health || exit 1

CMD ["./thinkific-client"]
