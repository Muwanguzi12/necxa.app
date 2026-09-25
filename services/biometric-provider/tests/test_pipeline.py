import unittest

from app.models import ModelBundle
from app.pipeline import BiometricPipeline, Scores


class FixedBackend:
    def __init__(self, scores: Scores):
        self.scores = scores

    def evaluate(self, selfie: bytes, reference: bytes | None) -> Scores:
        return self.scores


def pipeline(scores: Scores) -> BiometricPipeline:
    return BiometricPipeline(
        ModelBundle(revision="test-revision", ready=True),
        FixedBackend(scores),
        similarity_threshold=0.88,
        liveness_threshold=0.90,
    )


class BiometricPipelineTests(unittest.TestCase):
    def test_requires_both_matchers_and_liveness_to_pass(self):
        result = pipeline(Scores(0.96, 0.93, 0.95, False)).verify(b"selfie", b"reference", "face_match_and_liveness")
        self.assertEqual(result.decision, "pass")
        self.assertEqual(result.similarityScore, 0.93)

    def test_uses_the_weaker_matcher_score(self):
        result = pipeline(Scores(0.96, 0.70, 0.97, False)).verify(b"selfie", b"reference", "face_match_and_liveness")
        self.assertEqual(result.decision, "manual_review")
        self.assertEqual(result.reasonCode, "face_similarity_below_threshold")

    def test_spoof_signal_always_rejects(self):
        result = pipeline(Scores(0.99, 0.99, 0.99, True)).verify(b"selfie", b"reference", "face_match_and_liveness")
        self.assertEqual(result.decision, "reject")
        self.assertTrue(result.spoofDetected)


if __name__ == "__main__":
    unittest.main()
