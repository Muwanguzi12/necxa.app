from typing import Literal

from pydantic import BaseModel, Field


class VerificationResult(BaseModel):
    faceMatch: bool
    similarityScore: float = Field(ge=0, le=1)
    livenessPassed: bool
    livenessScore: float = Field(ge=0, le=1)
    spoofDetected: bool
    decision: Literal["pass", "manual_review", "reject"]
    reasonCode: str
    provider: Literal["necxa_biometric"] = "necxa_biometric"
    modelRevision: str


class ErrorResult(BaseModel):
    code: str
    message: str
