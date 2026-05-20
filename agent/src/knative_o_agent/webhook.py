"""Alertmanager webhook → synthetic operator turn for the agent."""

from __future__ import annotations

from typing import Any

import structlog
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Request, status
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


def make_router(agent: KnativeAgent, settings: Settings) -> APIRouter:
    router = APIRouter()

    def _require_token(authorization: str | None = Header(default=None)) -> None:
        # Alertmanager sends "Authorization: Bearer <token>".
        expected = f"Bearer {settings.webhook_token}"
        if authorization != expected:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="bad token")

    @router.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @router.post(
        "/alerts",
        status_code=status.HTTP_202_ACCEPTED,
        dependencies=[Depends(_require_token)],
    )
    async def alerts(payload: AlertmanagerPayload, request: Request) -> dict[str, Any]:
        turn = _format_turn(payload)
        log.info("alert.received", alerts=len(payload.alerts), status=payload.status)
        if settings.agent_mode == "auto":
            reply = await agent.run(turn)
            log.info("alert.handled", reply_chars=len(reply))
            return {"accepted": True, "reply": reply}
        # In confirm mode we don't auto-apply; we surface the alert to the
        # operator-facing chat instead (out of scope for this scaffold —
        # for now we just log and accept).
        log.info("alert.queued_for_operator", turn=turn)
        return {"accepted": True, "queued": True}

    return router


def build_app(agent: KnativeAgent, settings: Settings) -> FastAPI:
    app = FastAPI(title="knative-o-agent", version="0.1.0")
    app.include_router(make_router(agent, settings))
    return app
