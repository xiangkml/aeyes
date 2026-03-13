import asyncio
import json
import logging
import math
import os
import uuid
from datetime import datetime, timedelta, timezone

from aiohttp import ClientSession, WSMsgType, web
from google.cloud import firestore
from google.cloud import logging as cloud_logging
from google.cloud import storage


GEMINI_WS_BASE = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)

INVALID_CLOSE_CODES = {1005, 1006, 1015}
MAX_SCREENSHOT_BYTES = int(os.getenv("MAX_SCREENSHOT_BYTES", str(5 * 1024 * 1024)))


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


project_id = os.getenv("GOOGLE_CLOUD_PROJECT") or os.getenv("GCP_PROJECT")
gemini_api_key = os.getenv("GEMINI_API_KEY", "").strip()
gcs_bucket_name = os.getenv("GCS_BUCKET_NAME", "").strip()
signed_url_ttl_hours = int(os.getenv("SIGNED_URL_TTL_HOURS", "24"))

try:
    cloud_logging.Client().setup_logging()
except Exception:
    logging.basicConfig(level=logging.INFO)

db = firestore.Client(project=project_id)
storage_client = storage.Client(project=project_id)


def normalize_label(value: str) -> str:
    return " ".join((value or "").strip().lower().split())


def safe_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_embedding(value):
    if value is None:
        return None
    if isinstance(value, list):
        parsed = [safe_float(item) for item in value]
        if any(item is None for item in parsed):
            return None
        return parsed
    if isinstance(value, str) and value.strip():
        try:
            raw = json.loads(value)
        except json.JSONDecodeError:
            return None
        if isinstance(raw, list):
            parsed = [safe_float(item) for item in raw]
            if any(item is None for item in parsed):
                return None
            return parsed
    return None


def parse_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y"}
    return False


def ensure_session_exists(session_id: str):
    doc_ref = db.collection("sessions").document(session_id)
    if not doc_ref.get().exists:
        return None, web.json_response({"error": "session not found"}, status=404)
    return doc_ref, None


def build_signed_url(bucket, object_path: str):
    if not object_path:
        return None, None
    try:
        expires_at = datetime.now(timezone.utc) + timedelta(hours=signed_url_ttl_hours)
        url = bucket.blob(object_path).generate_signed_url(
            version="v4",
            expiration=expires_at,
            method="GET",
        )
        return url, expires_at.isoformat()
    except Exception:
        logging.exception("failed to generate signed URL for %s", object_path)
        return None, None


def cosine_similarity(left, right):
    if not left or not right or len(left) != len(right):
        return None
    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(a * a for a in left))
    right_norm = math.sqrt(sum(b * b for b in right))
    if left_norm == 0 or right_norm == 0:
        return None
    return dot / (left_norm * right_norm)


def label_similarity(query_labels, candidate_labels):
    def simplify(value: str) -> str:
        normalized = normalize_label(value)
        return (
            normalized.replace("user's ", "")
            .replace("other person's ", "")
            .replace("someone else's ", "")
            .strip()
        )

    query = {simplify(item) for item in query_labels if item}
    candidate = {simplify(item) for item in candidate_labels if item}
    query.discard("")
    candidate.discard("")
    if not query or not candidate:
        return 0.0
    if query & candidate:
        return 1.0

    best_score = 0.0
    for query_item in query:
        for candidate_item in candidate:
            if query_item in candidate_item or candidate_item in query_item:
                best_score = max(best_score, 0.7)

            query_tokens = set(query_item.split())
            candidate_tokens = set(candidate_item.split())
            if query_tokens and candidate_tokens:
                overlap = len(query_tokens & candidate_tokens)
                if overlap > 0:
                    token_score = overlap / len(query_tokens | candidate_tokens)
                    best_score = max(best_score, 0.35 + (0.55 * token_score))

    return best_score


async def _read_image_part(part) -> tuple[bytes | None, web.Response | None]:
    if part is None:
        return None, web.json_response({"error": "missing image part"}, status=400)

    content_type = (part.headers.get("Content-Type", "").split(";", 1)[0]).strip().lower()
    filename = (part.filename or "").strip().lower()
    has_jpeg_filename = filename.endswith(".jpg") or filename.endswith(".jpeg")

    if content_type in {"image/jpeg", "image/jpg"}:
        is_valid_image = True
    elif content_type in {"application/octet-stream", ""} and has_jpeg_filename:
        # Some mobile multipart clients send octet-stream for byte uploads.
        is_valid_image = True
    else:
        is_valid_image = False

    if not is_valid_image:
        return None, web.json_response({"error": "image must be jpeg"}, status=400)

    chunks = []
    total = 0
    while True:
        chunk = await part.read_chunk(size=64 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_SCREENSHOT_BYTES:
            return None, web.json_response(
                {"error": f"image too large; max {MAX_SCREENSHOT_BYTES} bytes"},
                status=413,
            )
        chunks.append(chunk)

    data = b"".join(chunks)
    if not data:
        return None, web.json_response({"error": "empty image payload"}, status=400)
    return data, None


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


async def upload_screenshot(request: web.Request) -> web.Response:
    session_id = request.match_info["session_id"]
    doc_ref, error = ensure_session_exists(session_id)
    if error is not None:
        return error
    if not gcs_bucket_name:
        return web.json_response({"error": "GCS_BUCKET_NAME is not configured"}, status=503)

    multipart = await request.multipart()
    image_bytes = None
    fields = {}

    async for part in multipart:
        if part.name == "image":
            image_bytes, read_error = await _read_image_part(part)
            if read_error is not None:
                return read_error
            continue
        fields[part.name] = await part.text()

    if image_bytes is None:
        return web.json_response({"error": "missing image part"}, status=400)

    metadata = {}
    if "metadata" in fields and fields["metadata"].strip():
        try:
            metadata = json.loads(fields["metadata"])
        except json.JSONDecodeError:
            return web.json_response({"error": "metadata must be valid JSON"}, status=400)

    user_label = fields.get("userLabel") or metadata.get("userLabel") or ""
    ai_label = fields.get("aiLabel") or metadata.get("aiLabel") or ""
    if not user_label.strip() and not ai_label.strip():
        return web.json_response(
            {"error": "object label is required before screenshot upload"},
            status=400,
        )
    trigger_reason = fields.get("triggerReason") or metadata.get("triggerReason") or "unknown"
    confidence = safe_float(fields.get("confidence") or metadata.get("confidence"))
    repeat_count = int(safe_float(fields.get("repeatCount") or metadata.get("repeatCount")) or 0)
    width = int(safe_float(fields.get("width") or metadata.get("width")) or 0)
    height = int(safe_float(fields.get("height") or metadata.get("height")) or 0)
    frame_timestamp = fields.get("frameTimestamp") or metadata.get("frameTimestamp")
    embedding = parse_embedding(fields.get("embedding") or metadata.get("embedding"))

    trigger_flags = {
        "intentTrigger": parse_bool(fields.get("intentTrigger") or metadata.get("intentTrigger")),
        "confidenceTrigger": parse_bool(
            fields.get("confidenceTrigger") or metadata.get("confidenceTrigger")
        ),
        "repeatTrigger": parse_bool(fields.get("repeatTrigger") or metadata.get("repeatTrigger")),
        "manualTrigger": parse_bool(fields.get("manualTrigger") or metadata.get("manualTrigger")),
    }

    screenshot_id = uuid.uuid4().hex
    created_at = utc_now()
    object_path = f"sessions/{session_id}/screenshots/{created_at}_{screenshot_id}.jpg"

    bucket = storage_client.bucket(gcs_bucket_name)
    blob = bucket.blob(object_path)
    blob.upload_from_string(image_bytes, content_type="image/jpeg")
    signed_url, signed_expires_at = build_signed_url(bucket, object_path)

    labels = [item for item in [user_label, ai_label] if item]
    screenshot_doc = {
        "screenshotId": screenshot_id,
        "sessionId": session_id,
        "userLabel": user_label,
        "aiLabel": ai_label,
        "normalizedLabels": [normalize_label(item) for item in labels],
        "triggerReason": trigger_reason,
        "triggerFlags": trigger_flags,
        "confidence": confidence,
        "repeatCount": repeat_count,
        "embedding": embedding,
        "width": width,
        "height": height,
        "frameTimestamp": frame_timestamp,
        "gcsBucket": gcs_bucket_name,
        "gcsObjectPath": object_path,
        "gcsPath": f"gs://{gcs_bucket_name}/{object_path}",
        "imageUrl": signed_url,
        "imageUrlExpiresAt": signed_expires_at,
        "createdAt": created_at,
        "lastSeenAt": created_at,
    }

    doc_ref.collection("screenshots").document(screenshot_id).set(screenshot_doc)
    doc_ref.set(
        {
            "lastScreenshotAt": created_at,
            "lastScreenshotLabel": user_label or ai_label,
            "updatedAt": utc_now(),
        },
        merge=True,
    )

    return web.json_response(
        {
            "ok": True,
            "screenshotId": screenshot_id,
            "imageUrl": signed_url,
            "imageUrlExpiresAt": signed_expires_at,
            "gcsPath": screenshot_doc["gcsPath"],
            "labels": {
                "userLabel": user_label,
                "aiLabel": ai_label,
            },
        },
        status=201,
    )


async def list_screenshots(request: web.Request) -> web.Response:
    session_id = request.match_info["session_id"]
    doc_ref, error = ensure_session_exists(session_id)
    if error is not None:
        return error
    if not gcs_bucket_name:
        return web.json_response({"error": "GCS_BUCKET_NAME is not configured"}, status=503)

    try:
        limit = max(1, min(100, int(request.query.get("limit", "20"))))
    except ValueError:
        return web.json_response({"error": "invalid limit"}, status=400)

    bucket = storage_client.bucket(gcs_bucket_name)
    snapshots = (
        doc_ref.collection("screenshots")
        .order_by("createdAt", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .stream()
    )

    items = []
    for snapshot in snapshots:
        data = snapshot.to_dict() or {}
        object_path = data.get("gcsObjectPath", "")
        signed_url, signed_expires_at = build_signed_url(bucket, object_path)
        if signed_url:
            data["imageUrl"] = signed_url
            data["imageUrlExpiresAt"] = signed_expires_at
            snapshot.reference.set(
                {
                    "imageUrl": signed_url,
                    "imageUrlExpiresAt": signed_expires_at,
                },
                merge=True,
            )
        items.append(data)

    return web.json_response({"items": items})


async def match_screenshots(request: web.Request) -> web.Response:
    session_id = request.match_info["session_id"]
    doc_ref, error = ensure_session_exists(session_id)
    if error is not None:
        return error
    if not gcs_bucket_name:
        return web.json_response({"error": "GCS_BUCKET_NAME is not configured"}, status=503)

    payload = await request.json() if request.can_read_body else {}
    query_user_label = payload.get("userLabel", "")
    query_ai_label = payload.get("aiLabel", "")
    query_embedding = parse_embedding(payload.get("embedding"))
    query_labels = [query_user_label, query_ai_label]
    top_k = max(1, min(20, int(payload.get("topK", 5))))
    min_score = safe_float(payload.get("minScore"))
    min_score = 0.2 if min_score is None else max(0.0, min(1.0, min_score))

    bucket = storage_client.bucket(gcs_bucket_name)
    snapshots = (
        doc_ref.collection("screenshots")
        .order_by("createdAt", direction=firestore.Query.DESCENDING)
        .limit(200)
        .stream()
    )

    candidates = []
    for snapshot in snapshots:
        data = snapshot.to_dict() or {}
        candidate_labels = data.get("normalizedLabels") or [
            data.get("userLabel", ""),
            data.get("aiLabel", ""),
        ]
        label_score = label_similarity(query_labels, candidate_labels)
        vector_score = cosine_similarity(query_embedding, parse_embedding(data.get("embedding")))

        if vector_score is None:
            combined_score = label_score
        elif label_score <= 0:
            combined_score = vector_score
        else:
            combined_score = (0.45 * label_score) + (0.55 * vector_score)

        if combined_score < min_score:
            continue

        object_path = data.get("gcsObjectPath", "")
        signed_url, signed_expires_at = build_signed_url(bucket, object_path)
        if signed_url:
            data["imageUrl"] = signed_url
            data["imageUrlExpiresAt"] = signed_expires_at

        data["matchScore"] = round(combined_score, 5)
        data["labelScore"] = round(label_score, 5)
        data["vectorScore"] = round(vector_score, 5) if vector_score is not None else None
        candidates.append(data)

    candidates.sort(key=lambda item: item.get("matchScore", 0.0), reverse=True)
    return web.json_response({"items": candidates[:top_k]})


async def search_memories(request: web.Request) -> web.Response:
    if not gcs_bucket_name:
        return web.json_response({"error": "GCS_BUCKET_NAME is not configured"}, status=503)

    payload = await request.json() if request.can_read_body else {}
    query_user_label = payload.get("userLabel", "")
    query_ai_label = payload.get("aiLabel", "")
    query_embedding = parse_embedding(payload.get("embedding"))
    query_labels = [query_user_label, query_ai_label]
    top_k = max(1, min(20, int(payload.get("topK", 5))))
    min_score = safe_float(payload.get("minScore"))
    min_score = 0.2 if min_score is None else max(0.0, min(1.0, min_score))

    bucket = storage_client.bucket(gcs_bucket_name)
    snapshots = (
        db.collection_group("screenshots")
        .order_by("createdAt", direction=firestore.Query.DESCENDING)
        .limit(300)
        .stream()
    )

    candidates = []
    for snapshot in snapshots:
        data = snapshot.to_dict() or {}
        candidate_labels = data.get("normalizedLabels") or [
            data.get("userLabel", ""),
            data.get("aiLabel", ""),
        ]
        label_score = label_similarity(query_labels, candidate_labels)
        vector_score = cosine_similarity(query_embedding, parse_embedding(data.get("embedding")))

        if vector_score is None:
            combined_score = label_score
        elif label_score <= 0:
            combined_score = vector_score
        else:
            combined_score = (0.45 * label_score) + (0.55 * vector_score)

        if combined_score < min_score:
            continue

        object_path = data.get("gcsObjectPath", "")
        signed_url, signed_expires_at = build_signed_url(bucket, object_path)
        if signed_url:
            data["imageUrl"] = signed_url
            data["imageUrlExpiresAt"] = signed_expires_at

        data["matchScore"] = round(combined_score, 5)
        data["labelScore"] = round(label_score, 5)
        data["vectorScore"] = round(vector_score, 5) if vector_score is not None else None
        candidates.append(data)

    candidates.sort(key=lambda item: item.get("matchScore", 0.0), reverse=True)
    return web.json_response({"items": candidates[:top_k]})


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
    app.router.add_post("/v1/sessions/{session_id}/screenshots", upload_screenshot)
    app.router.add_get("/v1/sessions/{session_id}/screenshots", list_screenshots)
    app.router.add_post("/v1/sessions/{session_id}/screenshots/match", match_screenshots)
    app.router.add_post("/v1/memory/search", search_memories)
    app.router.add_get("/v1/live", live_proxy)
    return app


if __name__ == "__main__":
    web.run_app(create_app(), host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
