# syntax=docker/dockerfile:1.7

# ---- Build stage ----
FROM golang:1.24.13-bookworm AS builder

ARG NOBLE_REPO=https://github.com/strangelove-ventures/noble.git
ARG NOBLE_VERSION=v11.1.0-rc.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        git make gcc libc6-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch ${NOBLE_VERSION} ${NOBLE_REPO} noble
WORKDIR /src/noble
RUN make install

# ---- Runtime stage ----
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq lz4 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r cosmos && useradd -r -g cosmos -m -d /home/cosmos cosmos

COPY --from=builder /go/bin/nobled /usr/local/bin/nobled

USER cosmos
WORKDIR /home/cosmos
ENV DAEMON_HOME=/home/cosmos/.nobled

EXPOSE 26656 26657 1317 9090

ENTRYPOINT ["nobled"]
CMD ["start"]
