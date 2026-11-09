"""compare / parse unit tests (P6.2): python3 -m unittest discover -s scripts/benchmarks/tests"""
import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import results  # noqa: E402

def write(obj):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(obj, f); f.close(); return f.name

BASE = {"schema": 1, "scenarios": {
    "launch-warm": {"first_window": {"median": 250.0, "p90": 260.0, "unit": "ms", "runs": 10}},
    "idle-1tabs": {"cpu_percent": {"median": 0.0, "p90": 0.0, "unit": "%", "runs": 1},
                   "footprint": {"median": 60.0, "p90": 60.0, "unit": "MB", "runs": 1}},
}}

class CompareTests(unittest.TestCase):
    def run_compare(self, candidate, loose=False):
        return results.compare(write(BASE), write(candidate), loose)

    def test_pass_within_thresholds(self):
        cand = json.loads(json.dumps(BASE))
        cand["scenarios"]["launch-warm"]["first_window"]["median"] = 270.0  # +8 %
        cand["scenarios"]["idle-1tabs"]["cpu_percent"]["median"] = 0.05    # +0.05 pt
        self.assertEqual(self.run_compare(cand), 0)

    def test_regression_detected(self):
        cand = json.loads(json.dumps(BASE))
        cand["scenarios"]["launch-warm"]["first_window"]["median"] = 300.0  # +20 %
        self.assertEqual(self.run_compare(cand), 1)
        cand = json.loads(json.dumps(BASE))
        cand["scenarios"]["idle-1tabs"]["cpu_percent"]["median"] = 0.5     # +0.5 pt
        self.assertEqual(self.run_compare(cand), 1)

    def test_loose_mode_tolerates_ci_noise(self):
        cand = json.loads(json.dumps(BASE))
        cand["scenarios"]["launch-warm"]["first_window"]["median"] = 300.0  # +20 % < 25 %
        self.assertEqual(self.run_compare(cand, loose=True), 0)

    def test_missing_metric_fails(self):
        cand = json.loads(json.dumps(BASE))
        del cand["scenarios"]["idle-1tabs"]["footprint"]
        self.assertEqual(self.run_compare(cand), 1)

    def test_improvement_passes(self):
        cand = json.loads(json.dumps(BASE))
        cand["scenarios"]["launch-warm"]["first_window"]["median"] = 100.0
        self.assertEqual(self.run_compare(cand), 0)

class ParseTests(unittest.TestCase):
    def test_parses_scenario_and_graph_lines(self):
        scenarios, errors = results.parse([
            "scenario=open-repo metric=repo.open median=120.5 p90=130.0 max=140.0 n=10 unit=ms",
            "scenario=multi-tab metric=footprint value=180.2 unit=MB tabs=5",
            "scenario=open-close-loop metric=footprint first=50.0 after10=60.0 last=61.0 settled=60.5 cycles=50 unit=MB",
            "graph_scroll_step_ms median=1.50 p95=1.90 max=10.00 n=400 over_16ms=0",
            "scenario=launch-cold error=not-measured reason=needs-sudo-purge",
        ])
        self.assertEqual(scenarios["open-repo"]["repo.open"]["median"], 120.5)
        self.assertEqual(scenarios["multi-tab"]["footprint"]["unit"], "MB")
        self.assertEqual(scenarios["open-close-loop"]["footprint.settled"]["median"], 60.5)
        self.assertEqual(scenarios["graph-scroll"]["scroll_step"]["over_16ms"], 0)
        self.assertEqual(errors[0]["scenario"], "launch-cold")

if __name__ == "__main__":
    unittest.main()
