from contextlib import asynccontextmanager
import hmac
from io import BytesIO
from typing import Annotated

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from PIL import Image, UnidentifiedImageError

from .contracts import ErrorResult, VerificationResult
from .models import load_model_bundle
from .pipeline import BiometricPipeline, UnavailableBackend
from .settings import Settings, get_settings


def require_token(authorization: Annotated[str | None, Header()] = None, settings: Settings = Depends(get_settings)) -> None:
    supplied = authorization.removeprefix("Bearer ") if authorization else ""
    if not hmac.compare_digest(supplied, settings.api_token):
        raise HTTPException(status_code=401, detail={"code": "unauthorized", "message": "Valid bearer token required"})


async def read_image(upload: UploadFile, settings: Settings) -> bytes:
    data = await upload.read(settings.max_image_bytes + 1)
    if not data or len(data) > settings.max_image_bytes:
        raise HTTPException(status_code=413, detail={"code": "invalid_image_size", "message": "Image is empty or too large"})
    try:
        with Image.open(BytesIO(data)) as image:
            image.verify()
            if image.width < 160 or image.height < 160:
                raise HTTPException(status_code=422, detail={"code": "image_too_small", "message": "Image dimensions are too small"})
    except (UnidentifiedImageError, OSError):
        raise HTTPException(status_code=422, detail={"code": "invalid_image", "message": "Unsupported or corrupt image"})
    return data


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    bundle = load_model_bundle(settings.model_manifest)
    app.state.pipeline = BiometricPipeline(bundle, UnavailableBackend(), settings.similarity_threshold, settings.liveness_threshold)
    yield


app = FastAPI(title="Necxa Biometric Provider", version="0.1.0", docs_url=None, redoc_url=None, lifespan=lifespan)


@app.get("/healthz")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz", dependencies=[Depends(require_token)])
def readiness() -> dict[str, str | bool]:
    bundle = app.state.pipeline.bundle
    return {"ready": bundle.ready, "revision": bundle.revision, "reason": bundle.reason or "ready"}


@app.post("/v1/verify", response_model=VerificationResult, responses={401: {"model": ErrorResult}, 503: {"model": ErrorResult}}, dependencies=[Depends(require_token)])
async def verify(
    selfie: Annotated[UploadFile, File()],
    reference: Annotated[UploadFile | None, File()] = None,
    mode: Annotated[str, Form(pattern="^(liveness|face_match_and_liveness)$")] = "face_match_and_liveness",
    settings: Settings = Depends(get_settings),
) -> VerificationResult:
    if mode == "face_match_and_liveness" and reference is None:
        raise HTTPException(status_code=422, detail={"code": "reference_required", "message": "Reference image is required"})
    selfie_bytes = await read_image(selfie, settings)
    reference_bytes = await read_image(reference, settings) if reference else None
    try:
        return app.state.pipeline.verify(selfie_bytes, reference_bytes, mode)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail={"code": str(exc), "message": "Biometric models are not ready"}) from exc
