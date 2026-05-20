"""CLI entry point: `knative-o-agent serve` and `knative-o-agent prompt ...`."""

from __future__ import annotations

import asyncio
import logging

import structlog
import typer
import uvicorn

from .agent import KnativeAgent
from .config import Settings
from .webhook import build_app

app = typer.Typer(help="LangChain agent for Knative-O")


def _configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.JSONRenderer(),
        ]
    )


@app.command()
def serve() -> None:
    """Run the FastAPI webhook + keep the agent process alive."""
    _configure_logging()
    settings = Settings()

    async def _main() -> None:
        agent = KnativeAgent(settings)
        await agent.start()
        try:
            api = build_app(agent, settings)
            config = uvicorn.Config(
                api,
                host=settings.webhook_host,
                port=settings.webhook_port,
                log_level="info",
            )
            server = uvicorn.Server(config)
            await server.serve()
        finally:
            await agent.stop()

    asyncio.run(_main())


@app.command()
def prompt(message: str) -> None:
    """One-shot prompt against the agent; useful for local smoke tests."""
    _configure_logging()
    settings = Settings()

    async def _run() -> None:
        agent = KnativeAgent(settings)
        await agent.start()
        try:
            reply = await agent.run(message)
            typer.echo(reply)
        finally:
            await agent.stop()

    asyncio.run(_run())


if __name__ == "__main__":
    app()
