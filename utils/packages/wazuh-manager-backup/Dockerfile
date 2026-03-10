ARG AWS_CLI_VERSION=2.22.35
ARG KUBECTL_VERSION=v1.31.0
ARG HELM_VERSION=v3.17.1

## ── Stage 1: download and verify kubectl + helm ─────────────────────────────
## Alpine has curl, tar, and sha256sum available via a single apk add.
FROM alpine:3.21 AS builder

RUN apk add --no-cache curl tar

ARG KUBECTL_VERSION
ARG HELM_VERSION

RUN curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
    && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl kubectl.sha256 \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" -o "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
    && sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
    && tar -zxf "helm-${HELM_VERSION}-linux-amd64.tar.gz" linux-amd64/helm \
    && install -o root -g root -m 0755 linux-amd64/helm /usr/local/bin/helm \
    && rm -rf "helm-${HELM_VERSION}-linux-amd64.tar.gz" "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" linux-amd64

## ── Stage 2: runtime image ───────────────────────────────────────────────────
## amazon/aws-cli provides the aws binary. kubectl and helm are copied from the
## builder stage — no extra packages or layer bloat in the final image.
FROM amazon/aws-cli:${AWS_CLI_VERSION}

COPY --from=builder /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=builder /usr/local/bin/helm    /usr/local/bin/helm
