from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    llm_model: str = "claude-sonnet-4-6"
    anthropic_api_key: str | None = None
    openai_api_key: str | None = None

    mcp_server_command: str = "kubernetes-mcp-server"
    mcp_server_args: list[str] = []

    demo_namespace: str = "astronomy-shop"
    agent_mode: Literal["confirm", "auto"] = "confirm"

    webhook_host: str = "0.0.0.0"
    webhook_port: int = 8080
    webhook_token: str = "change-me"

    langchain_tracing_v2: bool = False
    langchain_api_key: str | None = None
    langchain_project: str = "knative-o"

    @property
    def provider(self) -> Literal["anthropic", "openai"]:
        if self.llm_model.startswith("claude"):
            return "anthropic"
        return "openai"
