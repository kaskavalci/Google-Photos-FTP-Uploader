FROM golang:alpine AS builder
RUN apk add --no-cache git ca-certificates make
WORKDIR /build
RUN git clone --depth 1 https://github.com/gphotosuploader/gphotos-uploader-cli.git . && \
    make build

FROM alpine:latest
RUN apk add --no-cache \
    bash \
    exiftool \
    findutils \
    rsync \
    tzdata \
    ca-certificates

COPY --from=builder /build/gphotos-uploader-cli /usr/local/bin/
COPY watcher.sh /usr/local/bin/watcher.sh
RUN chmod +x /usr/local/bin/watcher.sh

# Run as 1000 so files created in /config match volume ownership; SFTPGo also runs as 1000 so inbox files are deletable
RUN adduser -D -u 1000 -g "app" appuser
USER 1000
CMD ["/usr/local/bin/watcher.sh"]
