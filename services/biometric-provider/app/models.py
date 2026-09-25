from dataclasses import dataclass
from pathlib import Path
import hashlib
import json


REQUIRED_ROLES = {"detector", "embedder_primary", "embedder_secondary", "presentation_attack_detection"}


@dataclass(frozen=True)
class ModelBundle:
    revision: str
    ready: bool
    reason: str | None = None


def load_model_bundle(manifest_path: str) -> ModelBundle:
    path = Path(manifest_path)
    if not path.is_file():
        return ModelBundle(revision="unconfigured", ready=False, reason="model_manifest_missing")
    try:
        raw = path.read_bytes()
        data = json.loads(raw)
        roles = {item["role"] for item in data.get("models", []) if item.get("approved_for_production") is True}
        if not REQUIRED_ROLES.issubset(roles):
            return ModelBundle(revision="incomplete", ready=False, reason="approved_model_roles_missing")
        for item in data["models"]:
            if item["role"] not in REQUIRED_ROLES or item.get("approved_for_production") is not True:
                continue
            model_path = Path(item["path"])
            if not model_path.is_file():
                return ModelBundle(revision="incomplete", ready=False, reason=f"model_file_missing:{item['role']}")
            digest = hashlib.sha256(model_path.read_bytes()).hexdigest()
            if digest.lower() != str(item.get("sha256", "")).lower():
                return ModelBundle(revision="invalid", ready=False, reason=f"model_checksum_mismatch:{item['role']}")
        revision = hashlib.sha256(raw).hexdigest()[:16]
        return ModelBundle(revision=revision, ready=True)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return ModelBundle(revision="invalid", ready=False, reason="model_manifest_invalid")
