from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


def _empty_to_none(v: object) -> object:
    # Kubernetes secretKeyRef with optional=True omits the env var when the
    # key is missing, but if the key exists with an empty value the env var
    # is set to "". Treat that as unset so the "Claude needs Anthropic key"
    # check doesn't fire on an explicitly empty string.
    if isinstance(v, str) and not v.strip():
        return None
    return v


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    llm_model: str = "gpt-4o"
    anthropic_api_key: str | None = None
    openai_api_key: str | None = None

    mcp_server_command: str = "kubernetes-mcp-server"
    mcp_server_args: list[str] = []
    # When set, forces kubernetes-mcp-server's connection strategy. In a pod
    # set this to "in-cluster" — auto-detection can fail with
    # "no configuration has been provided / KUBERNETES_MASTER". Leave unset
    # locally so it falls back to your ~/.kube/config.
    mcp_cluster_provider: str | None = None

    demo_namespace: str = "astronomy-shop"
    agent_mode: Literal["confirm", "auto"] = "confirm"

    webhook_host: str = "0.0.0.0"
    webhook_port: int = 8080
    webhook_token: str = "change-me"

    langchain_tracing_v2: bool = False
    langchain_api_key: str | None = None
    langchain_project: str = "knative-o"

    _empty_to_none = field_validator(
        "anthropic_api_key", "openai_api_key", "langchain_api_key", mode="before"
    )(_empty_to_none)

    @property
    def provider(self) -> Literal["anthropic", "openai"]:
        if self.llm_model.startswith("claude"):
            return "anthropic"
        return "openai"
