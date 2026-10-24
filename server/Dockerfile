FROM golang:1.23-alpine AS build
WORKDIR /src
ARG PAIRDESK_BUILD_COMMIT=unknown
RUN mkdir -p /data
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X pairdesk/server/internal/app.buildCommit=${PAIRDESK_BUILD_COMMIT}" -o /out/pairdesk-api ./cmd/pairdesk-api && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/pairdesk-admin ./cmd/pairdesk-admin
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/pairdesk-api /pairdesk-api
COPY --from=build /out/pairdesk-admin /pairdesk-admin
COPY --from=build --chown=nonroot:nonroot /data /data
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/pairdesk-api"]
