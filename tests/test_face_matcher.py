import unittest
import numpy as np

from scripts.face_matcher import FaceMatcher, score_similarity


class FaceMatcherTests(unittest.TestCase):
    def test_identical_vectors_score_at_one(self):
        self.assertAlmostEqual(score_similarity(np.array([1.0, 0.0]), np.array([1.0, 0.0])), 1.0)

    def test_low_similarity_is_rejected(self):
        matcher = FaceMatcher(index_type="flat")
        matcher.add_user("user-1", np.array([1.0, 0.0, 0.0], dtype=np.float32))
        matcher.add_user("user-2", np.array([0.0, 1.0, 0.0], dtype=np.float32))

        result = matcher.match(np.array([0.2, 0.8, 0.0], dtype=np.float32), threshold=0.85)
        self.assertIsNone(result)

    def test_high_similarity_returns_matching_user(self):
        matcher = FaceMatcher(index_type="flat")
        matcher.add_user("user-1", np.array([1.0, 0.0, 0.0], dtype=np.float32))
        matcher.add_user("user-2", np.array([0.0, 1.0, 0.0], dtype=np.float32))

        result = matcher.match(np.array([1.0, 0.0, 0.0], dtype=np.float32), threshold=0.8)
        self.assertIsNotNone(result)
        self.assertEqual(result["user_id"], "user-1")
        self.assertGreaterEqual(result["score"], 0.8)


if __name__ == "__main__":
    unittest.main()
