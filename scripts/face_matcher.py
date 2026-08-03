import os
from dataclasses import dataclass
from typing import Optional

import numpy as np

try:
    import faiss
except ImportError:  # pragma: no cover
    faiss = None

try:
    import cv2
    from insightface.app import FaceAnalysis
except ImportError:  # pragma: no cover
    cv2 = None
    FaceAnalysis = None


@dataclass
class MatchResult:
    user_id: str
    score: float
    matched: bool


class FaceMatcher:
    def __init__(self, index_type: str = "flat", dimension: Optional[int] = None):
        self.dimension = dimension
        self.index_type = index_type
        self._ids: list[str] = []
        self._vectors: list[np.ndarray] = []
        self.index = None
        self._analyzer = self._load_analyzer()

        if faiss is not None and self.dimension is not None:
            if index_type == "ivf":
                self.index = faiss.IndexIVFFlat(faiss.IndexFlatL2(self.dimension), self.dimension, 16, faiss.METRIC_L2)
            else:
                self.index = faiss.IndexFlatIP(self.dimension)

    @staticmethod
    def _load_analyzer():
        if FaceAnalysis is None or cv2 is None:
            return None
        try:
            app = FaceAnalysis(name='buffalo_l', providers=['CPUExecutionProvider'])
            app.prepare(ctx_id=0, det_size=(640, 640))
            return app
        except Exception:
            return None

    def add_user(self, user_id: str, vector: np.ndarray) -> None:
        vector = np.asarray(vector, dtype=np.float32).reshape(1, -1)
        if self.dimension is not None and vector.shape[1] != self.dimension:
            raise ValueError(f"expected dimension {self.dimension}, got {vector.shape[1]}")
        if self.dimension is None:
            self.dimension = vector.shape[1]
            self._reset_index()

        self._ids.append(user_id)
        self._vectors.append(vector[0])
        if self.index is not None:
            self.index.add(vector)

    def add_user_from_image(self, user_id: str, image_path: str) -> np.ndarray:
        embedding = extract_embedding_from_image(image_path, analyzer=self._analyzer)
        if embedding is None:
            raise ValueError(f"no face detected in {image_path}")
        self.add_user(user_id, embedding)
        return embedding

    def match(self, candidate_vector: np.ndarray, threshold: float = 0.8) -> Optional[dict]:
        candidate = np.asarray(candidate_vector, dtype=np.float32).reshape(1, -1)
        if self.dimension is None:
            self.dimension = candidate.shape[1]
            self._reset_index()
        if self.dimension is not None and candidate.shape[1] != self.dimension:
            raise ValueError(f"expected dimension {self.dimension}, got {candidate.shape[1]}")

        if self.index is None or self.index.ntotal == 0:
            return None

        scores, indices = self.index.search(candidate, 1)
        best_score = float(scores[0][0])
        best_index = int(indices[0][0])

        if best_index < 0:
            return None

        if best_score < threshold:
            return None

        return {
            "user_id": self._ids[best_index],
            "score": best_score,
            "matched": True,
        }

    def match_image(self, image_path: str, threshold: float = 0.8) -> Optional[dict]:
        embedding = extract_embedding_from_image(image_path, analyzer=self._analyzer)
        if embedding is None:
            return None
        return self.match(embedding, threshold=threshold)

    def _reset_index(self) -> None:
        self.index = None
        if faiss is not None and self.dimension is not None:
            if self.index_type == "ivf":
                self.index = faiss.IndexIVFFlat(faiss.IndexFlatL2(self.dimension), self.dimension, 16, faiss.METRIC_L2)
            else:
                self.index = faiss.IndexFlatIP(self.dimension)


def extract_embedding_from_image(image_path: str, analyzer=None) -> Optional[np.ndarray]:
    if cv2 is None or FaceAnalysis is None or analyzer is None:
        return None

    if not os.path.exists(image_path):
        raise FileNotFoundError(image_path)

    image = cv2.imread(image_path)
    if image is None:
        raise ValueError(f"could not read {image_path}")

    faces = analyzer.get(image)
    if not faces:
        return None

    face = max(faces, key=lambda item: item.det_score)
    embedding = np.asarray(face.embedding, dtype=np.float32)
    return embedding / np.linalg.norm(embedding)


def score_similarity(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=np.float32)
    b = np.asarray(b, dtype=np.float32)
    if a.shape != b.shape:
        raise ValueError("vectors must have the same shape")
    denom = (np.linalg.norm(a) * np.linalg.norm(b)) or 1.0
    return float(np.dot(a, b) / denom)
