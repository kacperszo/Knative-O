# syntax=docker/dockerfile:1.7
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY pyproject.toml ./
COPY src ./src
RUN pip install --user .

# kubernetes-mcp-server binary — downloaded once at build time.
ARG MCP_VERSION=0.0.46
ARG TARGETARCH=amd64
ADD https://github.com/containers/kubernetes-mcp-server/releases/download/v${MCP_VERSION}/kubernetes-mcp-server-linux-${TARGETARCH} /usr/local/bin/kubernetes-mcp-server
RUN chmod +x /usr/local/bin/kubernetes-mcp-server

FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 \
    PATH=/home/agent/.local/bin:/usr/local/bin:$PATH

RUN useradd -m -u 10001 agent
USER agent
WORKDIR /home/agent

COPY --from=builder --chown=agent:agent /root/.local /home/agent/.local
COPY --from=builder /usr/local/bin/kubernetes-mcp-server /usr/local/bin/kubernetes-mcp-server

EXPOSE 8080
ENTRYPOINT ["knative-o-agent"]
CMD ["serve"]
