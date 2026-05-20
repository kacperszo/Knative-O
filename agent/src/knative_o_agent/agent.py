"""LangChain ReAct agent backed by kubernetes-mcp-server tools."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import AsyncIterator

import structlog
from langchain_core.language_models import BaseChatModel
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_mcp_adapters.client import MultiServerMCPClient
from langgraph.prebuilt import create_react_agent

from .config import Settings
from .prompts import render as render_system

log = structlog.get_logger()


def _build_llm(settings: Settings) -> BaseChatModel:
    if settings.provider == "anthropic":
        from langchain_anthropic import ChatAnthropic

        if not settings.anthropic_api_key:
            raise RuntimeError("ANTHROPIC_API_KEY is required for Claude models")
        return ChatAnthropic(
            model=settings.llm_model,
            anthropic_api_key=settings.anthropic_api_key,
            temperature=0,
            max_tokens=2048,
        )
    from langchain_openai import ChatOpenAI

    if not settings.openai_api_key:
        raise RuntimeError("OPENAI_API_KEY is required for GPT models")
    return ChatOpenAI(
        model=settings.llm_model,
        openai_api_key=settings.openai_api_key,
        temperature=0,
    )


class KnativeAgent:
    """Wraps an MCP client + a ReAct agent. Owns the conversation history."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._mcp_client: MultiServerMCPClient | None = None
        self._agent = None
        self._history: list = []
        self._lock = asyncio.Lock()

    async def start(self) -> None:
        self._mcp_client = MultiServerMCPClient(
            {
                "kubernetes": {
                    "command": self.settings.mcp_server_command,
                    "args": self.settings.mcp_server_args,
                    "transport": "stdio",
                }
            }
        )
        tools = await self._mcp_client.get_tools()
        log.info("mcp.tools_loaded", count=len(tools))
        llm = _build_llm(self.settings)
        self._agent = create_react_agent(
            llm,
            tools=tools,
            prompt=SystemMessage(
                content=render_system(
                    demo_namespace=self.settings.demo_namespace,
                    agent_mode=self.settings.agent_mode,
                )
            ),
        )

    async def stop(self) -> None:
        if self._mcp_client is not None:
            await self._mcp_client.close()

    async def run(self, user_message: str) -> str:
        if self._agent is None:
            raise RuntimeError("Agent not started")
        async with self._lock:
            self._history.append(HumanMessage(content=user_message))
            result = await self._agent.ainvoke({"messages": self._history})
            messages = result["messages"]
            self._history = messages
            for msg in reversed(messages):
                if isinstance(msg, AIMessage) and msg.content:
                    return msg.content if isinstance(msg.content, str) else str(msg.content)
            return "(no response)"


@asynccontextmanager
async def lifespan(settings: Settings) -> AsyncIterator[KnativeAgent]:
    agent = KnativeAgent(settings)
    await agent.start()
    try:
        yield agent
    finally:
        await agent.stop()
