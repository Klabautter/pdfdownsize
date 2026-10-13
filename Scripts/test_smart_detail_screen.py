"""Meaningful negative controls for the offline protected-region screen."""
import unittest
from PIL import Image, ImageDraw
from smart_detail_screen import evaluate


class ProtectedScreenTests(unittest.TestCase):
    def setUp(self):
        self.reference = Image.new("RGB", (1000, 1000), "white")
        ImageDraw.Draw(self.reference).line((40, 40, 60, 40), fill="black", width=2)
        self.spec = {"reference_size": [1000, 1000], "reference_ppi": 192,
                     "regions": [{"id": "axis", "kind": "line", "box": [38, 38, 64, 44],
                                  "minimum_psnr_db": 25}]}

    def test_identical_is_screen_pass_but_never_semantic_approval(self):
        report = evaluate(self.reference, self.reference, self.spec)
        self.assertTrue(report["protected_screen_pass"])
        self.assertEqual(report["semantic_acceptance"], "pending")
        self.assertFalse(report["release_accepted"])
        self.assertTrue(report["view_metrics"][-1]["diagnostic_only"])

    def test_tiny_erasure_hidden_in_global_score_is_rejected_locally(self):
        candidate = Image.new("RGB", self.reference.size, "white")
        report = evaluate(self.reference, candidate, self.spec)
        self.assertGreater(report["view_metrics"][1]["psnr_db"], 35)
        self.assertFalse(report["protected_screen_pass"])

    def test_shifted_line_is_rejected(self):
        candidate = Image.new("RGB", self.reference.size, "white")
        ImageDraw.Draw(candidate).line((40, 42, 60, 42), fill="black", width=2)
        self.assertFalse(evaluate(self.reference, candidate, self.spec)["protected_screen_pass"])

    def test_absent_regions_and_outside_boxes_fail_closed(self):
        for regions in ([], [{**self.spec["regions"][0], "box": [-1, 0, 10, 10]}]):
            with self.assertRaises(ValueError):
                evaluate(self.reference, self.reference, {**self.spec, "regions": regions})

    def test_renderer_size_mismatch_fails(self):
        with self.assertRaises(ValueError):
            evaluate(self.reference, self.reference.resize((500, 500)), self.spec)


if __name__ == "__main__":
    unittest.main()
