FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY main.go .
RUN go build -o token-hook main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/token-hook .

EXPOSE 8080
CMD ["./token-hook"]
