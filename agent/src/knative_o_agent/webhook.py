"""Alertmanager webhook → synthetic operator turn for the agent."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass, field
from typing import Any

import structlog
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from .agent import KnativeAgent
from .config import Settings

log = structlog.get_logger()


class Alert(BaseModel):
    status: str
    labels: dict[str, Any] = {}
    annotations: dict[str, Any] = {}
    startsAt: str | None = None
    endsAt: str | None = None


class AlertmanagerPayload(BaseModel):
    version: str | None = None
    groupKey: str | None = None
    status: str
    receiver: str | None = None
    alerts: list[Alert] = []


@dataclass
class AgentState:
    """Holds the agent and its init status across the FastAPI lifespan."""

    agent: KnativeAgent | None = None
    ready: bool = False
    error: str | None = None
    init_task: asyncio.Task | None = field(default=None, repr=False)


def _format_turn(payload: AlertmanagerPayload) -> str:
    lines = [
        f"Alert payload received from Alertmanager (status={payload.status}).",
        "Decide whether and how to remediate. Use the kubernetes tools to inspect first.",
        "",
    ]
    for a in payload.alerts:
        name = a.labels.get("alertname", "unknown")
        ns = a.labels.get("namespace_name") or a.labels.get("namespace") or "?"
        summary = a.annotations.get("summary", "")
        hint = a.annotations.get("remediation_hint", "")
        lines.append(
            f"- [{a.status}] {name} in {ns}: {summary}"
            + (f"  hint: {hint}" if hint else "")
        )
    return "\n".join(lines)


async def _init_agent(state: AgentState, settings: Settings) -> None:
    """Run agent.start() in the background so uvicorn binds the port first."""
    try:
        log.info("agent.init.start")
        agent = KnativeAgent(settings)
        await agent.start()
        state.agent = agent
        state.ready = True
        log.info("agent.init.ready")
    except Exception as e:  # noqa: BLE001
        state.error = f"{type(e).__name__}: {e}"
        log.exception("agent.init.failed", error=state.error)


def make_router(settings: Settings) -> APIRouter:
    router = APIRouter()

    def _require_token(authorization: str | None = Header(default=None)) -> None:
        # Alertmanager sends "Authorization: Bearer <token>".
        expected = f"Bearer {settings.webhook_token}"
        if authorization != expected:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="bad token")

    @router.get("/healthz")
    async def healthz() -> dict[str, str]:
        # Liveness only: the process is alive and serving. We deliberately
        # do not wait on agent init here — if MCP is broken we want the pod
        # to stay up so you can `kubectl logs` it instead of CrashLoopBackOff.
        return {"status": "ok"}

    @router.get("/readyz")
    async def readyz(request: Request) -> JSONResponse:
        state: AgentState = request.app.state.agent_state
        if state.ready:
            return JSONResponse({"status": "ready"})
        body: dict[str, Any] = {"status": "initializing"}
        if state.error:
            body = {"status": "error", "error": state.error}
        return JSONResponse(body, status_code=status.HTTP_503_SERVICE_UNAVAILABLE)

    @router.post(
        "/alerts",
        status_code=status.HTTP_202_ACCEPTED,
        dependencies=[Depends(_require_token)],
    )
    async def alerts(payload: AlertmanagerPayload, request: Request) -> dict[str, Any]:
        state: AgentState = request.app.state.agent_state
        if not state.ready or state.agent is None:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=state.error or "agent still initializing",
            )
        turn = _format_turn(payload)
        log.info("alert.received", alerts=len(payload.alerts), status=payload.status)
        if settings.agent_mode == "auto":
            reply = await state.agent.run(turn)
            log.info("alert.handled", reply_chars=len(reply))
            return {"accepted": True, "reply": reply}
        log.info("alert.queued_for_operator", turn=turn)
        return {"accepted": True, "queued": True}

    return router


def build_app(settings: Settings) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        state = AgentState()
        app.state.agent_state = state
        # Kick off init concurrently with uvicorn starting to accept connections.
        state.init_task = asyncio.create_task(_init_agent(state, settings))
        try:
            yield
        finally:
            if state.init_task and not state.init_task.done():
                state.init_task.cancel()
                with suppress(asyncio.CancelledError):
                    await state.init_task
            if state.agent is not None:
                with suppress(Exception):
                    await state.agent.stop()

    app = FastAPI(title="knative-o-agent", version="0.1.0", lifespan=lifespan)
    app.include_router(make_router(settings))
    return app
