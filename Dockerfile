# syntax=docker/dockerfile:1.12
ARG GO_VERSION=1.26.5
ARG DEBIAN_VERSION=trixie-slim

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-trixie AS build
ARG TARGETOS TARGETARCH VERSION=dev COMMIT=unknown BUILD_DATE=unknown
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.buildDate=${BUILD_DATE}" \
      -o /out/toroute ./cmd/toroute

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-trixie AS netprobe-build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY tests/netprobe ./tests/netprobe
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/netprobe ./tests/netprobe

FROM scratch AS netprobe
COPY --from=netprobe-build /out/netprobe /netprobe
USER 65532:65532
ENTRYPOINT ["/netprobe"]

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-trixie AS proxycheck-build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY tests/proxycheck ./tests/proxycheck
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/proxycheck ./tests/proxycheck

FROM scratch AS proxycheck
COPY --from=proxycheck-build /out/proxycheck /proxycheck
COPY --from=proxycheck-build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
ENTRYPOINT ["/proxycheck"]

FROM debian:${DEBIAN_VERSION} AS runtime
ARG UID=65532 GID=65532 VERSION=dev COMMIT=unknown BUILD_DATE=unknown SOURCE=https://github.com/kabumatome/toroute
LABEL org.opencontainers.image.title="ToRoute" \
      org.opencontainers.image.description="Security-focused containerized Tor client proxy" \
      org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="Apache-2.0"
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      adduser obfs4proxy privoxy tini tor tor-geoipdb \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid "${GID}" toroute \
 && useradd --system --uid "${UID}" --gid "${GID}" \
      --home-dir /var/lib/toroute --shell /usr/sbin/nologin toroute \
 && install -d -o "${UID}" -g "${GID}" -m 0700 /var/lib/toroute /run/toroute
COPY --from=build /out/toroute /usr/local/bin/toroute
COPY LICENSE NOTICE THIRD_PARTY_NOTICES.md /usr/share/doc/toroute/
USER ${UID}:${GID}
EXPOSE 9050
HEALTHCHECK --interval=30s --timeout=6s --start-period=420s --start-interval=5s --retries=3 \
  CMD ["/usr/local/bin/toroute", "healthcheck", "--json"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/toroute"]
CMD ["run"]
