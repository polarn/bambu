# bambu-exporter, for the flux bambu-exporter Deployment: static binary on
# scratch with the CA bundle (it verifies Bambu's cloud broker), running as
# 65532 to match the manifests' securityContext.

FROM docker.io/library/golang:1.25-bookworm@sha256:ea341baa9bd5ba6784f6d7161ace70544349a6242d54d34a0fbfd2c4d51c9d58 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /bambu-exporter ./cmd/bambu-exporter

FROM scratch

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /bambu-exporter /bambu-exporter

USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["/bambu-exporter"]
