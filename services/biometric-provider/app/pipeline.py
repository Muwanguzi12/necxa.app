from dataclasses import dataclass
from typing import Protocol

from .contracts import VerificationResult
from .models import ModelBundle


@dataclass(frozen=True)
class Scores:
    primary_similarity: float
    secondary_similarity: float
    liveness: float
    spoof_detected: bool


class InferenceBackend(Protocol):
    def evaluate(self, selfie: bytes, reference: bytes | None) -> Scores: ...


class UnavailableBackend:
    def evaluate(self, selfie: bytes, reference: bytes | None) -> Scores:
        raise RuntimeError("inference_backend_not_installed")


class BiometricPipeline:
    def __init__(self, bundle: ModelBundle, backend: InferenceBackend, similarity_threshold: float, liveness_threshold: float):
        self.bundle = bundle
        self.backend = backend
        self.similarity_threshold = similarity_threshold
        self.liveness_threshold = liveness_threshold

    def verify(self, selfie: bytes, reference: bytes | None, mode: str) -> VerificationResult:
        if not self.bundle.ready:
            raise RuntimeError(self.bundle.reason or "models_not_ready")
        scores = self.backend.evaluate(selfie, reference)
        similarity = min(scores.primary_similarity, scores.secondary_similarity)
        liveness_passed = not scores.spoof_detected and scores.liveness >= self.liveness_threshold
        face_match = mode == "liveness" and liveness_passed or (reference is not None and similarity >= self.similarity_threshold)
        if scores.spoof_detected:
            decision, reason = "reject", "presentation_attack_detected"
        elif face_match and liveness_passed:
            decision, reason = "pass", "biometric_checks_passed"
        elif not liveness_passed:
            decision, reason = "manual_review", "liveness_below_threshold"
        else:
            decision, reason = "manual_review", "face_similarity_below_threshold"
        return VerificationResult(
            faceMatch=face_match,
            similarityScore=similarity,
            livenessPassed=liveness_passed,
            livenessScore=scores.liveness,
            spoofDetected=scores.spoof_detected,
            decision=decision,
            reasonCode=reason,
            modelRevision=self.bundle.revision,
        )
