# syntax=docker/dockerfile:1.7

FROM node:24-alpine AS frontend-builder

WORKDIR /src/frontend

RUN corepack enable

COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

COPY frontend/ ./
RUN pnpm run build


FROM golang:1.25-alpine AS backend-builder

WORKDIR /src

ARG TARGETOS=linux
ARG TARGETARCH
ARG VERSION=dev
ARG COMMIT=unknown

COPY go.mod go.sum ./
RUN --mount=type=cache,id=go-mod,target=/go/pkg/mod \
    go mod download

COPY . ./
COPY --from=frontend-builder /src/frontend/dist/ ./frontend/dist/

RUN --mount=type=cache,id=go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=go-build,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH}" \
    go build -trimpath \
      -ldflags="-s -w -X github.com/filebrowser/filebrowser/v2/version.Version=${VERSION} -X github.com/filebrowser/filebrowser/v2/version.CommitSHA=${COMMIT}" \
      -o /out/filebrowser .


FROM alpine:3.23 AS runtime-assets

RUN apk add --no-cache ca-certificates mailcap tini-static && \
    wget -O /JSON.sh \
      https://raw.githubusercontent.com/dominictarr/JSON.sh/0d5e5c77365f63809bf6e77ef44a1f34b0e05840/JSON.sh


FROM busybox:1.37.0-musl

ENV UID=1000 \
    GID=1000

RUN addgroup -g "$GID" user && \
    adduser -D -u "$UID" -G user user && \
    mkdir -p /config /database /srv && \
    chown -R user:user /config /database /srv

COPY --from=backend-builder --chown=user:user /out/filebrowser /bin/filebrowser
COPY --chown=user:user docker/common/ /
COPY --chown=user:user docker/alpine/ /
COPY --from=runtime-assets /sbin/tini-static /bin/tini
COPY --from=runtime-assets /JSON.sh /JSON.sh
COPY --from=runtime-assets /etc/ca-certificates.conf /etc/ca-certificates.conf
COPY --from=runtime-assets /etc/ca-certificates /etc/ca-certificates
COPY --from=runtime-assets /etc/mime.types /etc/mime.types
COPY --from=runtime-assets /etc/ssl /etc/ssl

RUN chmod +x /init.sh /healthcheck.sh /JSON.sh

HEALTHCHECK --start-period=2s --interval=5s --timeout=3s CMD ["/healthcheck.sh"]

USER user

VOLUME ["/srv", "/config", "/database"]

EXPOSE 80

ENTRYPOINT ["/bin/tini", "--", "/init.sh"]
