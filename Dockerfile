FROM golang:1.13-alpine

ENV CGO_ENABLED=0
ENV GOROOT=/usr/local/go
ENV GOPATH=${HOME}/go
ENV PATH=$PATH:${GOROOT}/bin

RUN apk update && apk add --no-cache \
    git && \
    go get github.com/go-delve/delve/cmd/dlv

WORKDIR /go/src/github.com/setlog/debug-k8s
EXPOSE 30123 8090

ENTRYPOINT ["/go/bin/dlv", "debug", ".", "--listen=:30123", "--accept-multiclient", "--headless=true", "--api-version=2"]
