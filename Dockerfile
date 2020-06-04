FROM golang:1.13-alpine

ENV CGO_ENABLED=0
ENV GOROOT=/usr/local/go
ENV GOPATH=${HOME}/go
ENV PATH=$PATH:${GOROOT}/bin

EXPOSE 30123
EXPOSE 8090

WORKDIR /go/src/github.com/setlog/debug-k8s

RUN apk update && apk add git && \
    go get github.com/go-delve/delve/cmd/dlv

ENTRYPOINT ["/go/bin/dlv", "debug", ".", "--listen=:30123", "--accept-multiclient", "--headless=true", "--api-version=2"]
