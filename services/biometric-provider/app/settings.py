from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="BIOMETRIC_", env_file=".env", extra="ignore")

    api_token: str = Field(min_length=32)
    model_manifest: str = "/models/manifest.json"
    max_image_bytes: int = Field(default=8 * 1024 * 1024, ge=1024, le=20 * 1024 * 1024)
    similarity_threshold: float = Field(default=0.88, ge=0, le=1)
    liveness_threshold: float = Field(default=0.90, ge=0, le=1)


@lru_cache
def get_settings() -> Settings:
    return Settings()
