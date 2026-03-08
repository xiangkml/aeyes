import asyncio
import logging
import os
import uuid
from datetime import datetime, timezone

from aiohttp import ClientSession, WSMsgType, web
from google.cloud import firestore
from google.cloud import logging as cloud_logging


GEMINI_WS_BASE = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)

INVALID_CLOSE_CODES = {1005, 1006, 1015}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


project_id = os.getenv("GOOGLE_CLOUD_PROJECT") or os.getenv("GCP_PROJECT")
gemini_api_key = os.getenv("GEMINI_API_KEY", "").strip()

try:
    cloud_logging.Client().setup_logging()
except Exception:
    logging.basicConfig(level=logging.INFO)

db = firestore.Client(project=project_id)


async def health(_: web.Request) -> web.Response:
    return web.json_response({"ok": True, "service": "aeyes-cloud-agent"})


async def create_session(request: web.Request) -> web.Response:
    payload = await request.json() if request.can_read_body else {}
    session_id = uuid.uuid4().hex
    doc = {
        "sessionId": session_id,
        "platform": payload.get("platform", "unknown"),
        "mode": payload.get("mode", "live_assistance"),
        "status": "active",
        "transport": "cloud_run_relay",
        "arCapabilities": payload.get("arCapabilities", {}),
        "createdAt": utc_now(),
        "updatedAt": utc_now(),
    }
    db.collection("sessions").document(session_id).set(doc)
    logging.info("created session %s", session_id)
    return web.json_response({"sessionId": session_id}, status=201)


async def update_context(request: web.Request) -> web.Response:
    session_id = request.match_info["session_id"]
    payload = await request.json() if request.can_read_body else {}
    doc_ref = db.collection("sessions").document(session_id)
    if not doc_ref.get().exists:
        return web.json_response({"error": "session not found"}, status=404)

    observation = {
        "mode": payload.get("mode", "live_assistance"),
        "sceneSummary": payload.get("sceneSummary", ""),
        "memoryContext": payload.get("memoryContext", ""),
        "transcript": payload.get("transcript", ""),
        "currentGoal": payload.get("currentGoal"),
        "arCapabilities": payload.get("arCapabilities", {}),
        "createdAt": utc_now(),
    }

    doc_ref.collection("observations").add(observation)
    doc_ref.set(
        {
            "mode": observation["mode"],
            "sceneSummary": observation["sceneSummary"],
            "memoryContext": observation["memoryContext"],
            "lastTranscript": observation["transcript"],
            "currentGoal": observation["currentGoal"],
            "arCapabilities": observation["arCapabilities"],
            "updatedAt": utc_now(),
        },
        merge=True,
    )
    return web.json_response({"ok": True})


async def close_session(request: web.Request) -> web.Response:
    session_id = request.match_info["session_id"]
    payload = await request.json() if request.can_read_body else {}
    doc_ref = db.collection("sessions").document(session_id)
    if not doc_ref.get().exists:
        return web.json_response({"error": "session not found"}, status=404)

    doc_ref.set(
        {
            "status": "closed",
            "closedAt": utc_now(),
            "closeReason": payload.get("reason", "ended"),
            "updatedAt": utc_now(),
        },
        merge=True,
    )
    return web.json_response({"ok": True})


async def get_session(request: web.Request) -> web.Response:
    session_id = request.match_info["session_id"]
    snapshot = db.collection("sessions").document(session_id).get()
    if not snapshot.exists:
        return web.json_response({"error": "session not found"}, status=404)
    return web.json_response(snapshot.to_dict())


async def live_proxy(request: web.Request) -> web.StreamResponse:
    if not gemini_api_key:
        return web.json_response(
            {"error": "GEMINI_API_KEY is not configured on Cloud Run"},
            status=500,
        )

    session_id = request.query.get("session_id")
    if session_id:
        db.collection("sessions").document(session_id).set(
            {
                "transport": "cloud_run_relay",
                "proxyConnectedAt": utc_now(),
                "updatedAt": utc_now(),
            },
            merge=True,
        )

    client_ws = web.WebSocketResponse(heartbeat=30)
    await client_ws.prepare(request)

    gemini_uri = f"{GEMINI_WS_BASE}?key={gemini_api_key}"
    logging.info("opening Gemini relay for session_id=%s", session_id)
    try:
        async with ClientSession() as session:
            async with session.ws_connect(gemini_uri, heartbeat=30) as upstream_ws:
                logging.info("Gemini upstream connected for session_id=%s", session_id)

                async def relay_client_to_upstream():
                    async for message in client_ws:
                        if message.type == WSMsgType.TEXT:
                            await upstream_ws.send_str(message.data)
                        elif message.type == WSMsgType.BINARY:
                            await upstream_ws.send_bytes(message.data)
                        elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED):
                            await upstream_ws.close()
                            break
                        elif message.type == WSMsgType.ERROR:
                            raise client_ws.exception() or RuntimeError("client websocket error")

                async def relay_upstream_to_client():
                    async for message in upstream_ws:
                        if message.type == WSMsgType.TEXT:
                            await client_ws.send_str(message.data)
                        elif message.type == WSMsgType.BINARY:
                            await client_ws.send_bytes(message.data)
                        elif message.type == WSMsgType.ERROR:
                            raise upstream_ws.exception() or RuntimeError("upstream websocket error")

                tasks = [
                    asyncio.create_task(relay_client_to_upstream()),
                    asyncio.create_task(relay_upstream_to_client()),
                ]
                done, pending = await asyncio.wait(
                    tasks,
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
                for task in done:
                    task.result()

                logging.info(
                    "closing Gemini relay for session_id=%s upstream_code=%s upstream_exception=%s",
                    session_id,
                    upstream_ws.close_code,
                    upstream_ws.exception(),
                )
                close_code = upstream_ws.close_code
                if close_code in INVALID_CLOSE_CODES or close_code is None:
                    close_code = 1011
                await client_ws.close(
                    code=close_code,
                    message=str(upstream_ws.exception() or "").encode()[:120],
                )
    except Exception as error:
        logging.exception("Gemini relay failed for session_id=%s", session_id)
        await client_ws.close(code=1011, message=str(error).encode()[:120])

    return client_ws


def create_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/health", health)
    app.router.add_post("/v1/sessions", create_session)
    app.router.add_post("/v1/sessions/{session_id}/context", update_context)
    app.router.add_post("/v1/sessions/{session_id}/close", close_session)
    app.router.add_get("/v1/sessions/{session_id}", get_session)
    app.router.add_get("/v1/live", live_proxy)
    return app


if __name__ == "__main__":
    web.run_app(create_app(), host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
