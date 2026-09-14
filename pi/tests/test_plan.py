import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("plan", Path(__file__).parents[1] / "workflow/plan.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture():
    return {
        "version": 2, "summary": "Add a feature",
        "context": {
            "baseRevision": "abc123", "facts": ["Existing source: src.ts"],
            "decisions": ["Use the existing interface"], "constraints": ["No network"],
            "nonGoals": ["Do not change auth"], "acceptance": ["User can select"],
            "validation": ["From repo root: npm test"], "risks": [],
            "readFirst": [{"path": "AGENTS.md", "why": "Instructions"}],
        },
        "tasks": [{
            "id": "T1", "title": "Add implementation", "files": ["new.ts"],
            "readFirst": [{"path": "src.ts", "why": "Existing conventions"}],
            "what": "Export choose()", "doneWhen": "From root: npm test -- choose", "deps": [],
        }, {
            "id": "T2", "title": "Add tests", "files": ["new.test.ts"],
            "readFirst": [{"path": "new.ts", "why": "Created by T1"}],
            "what": "Test choose()", "doneWhen": "From root: npm test", "deps": ["T1"],
        }],
    }


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for path in ("AGENTS.md", "src.ts"):
            (self.root / path).write_text("source")
        self.plan = fixture()

    def check(self):
        return module.validate(self.plan, self.root)

    def test_valid_with_prerequisite_generated_source(self):
        self.check()

    def test_cli_check_render_and_brief(self):
        plan_path = self.root / ".pi/plan.json"
        plan_path.parent.mkdir()
        plan_path.write_text(json.dumps(self.plan))
        helper = Path(module.__file__)
        def run(*args):
            result = subprocess.run([sys.executable, str(helper), *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout
        self.assertIn("sha256=", run("check", str(plan_path)))
        self.assertEqual(run("render", str(plan_path)), f"Saved {plan_path.with_suffix('.md')}\n")
        self.assertEqual(plan_path.with_suffix(".md").read_text(), module.render(self.plan))
        brief_path = self.root / ".pi/briefs/T2.md"
        run("brief", str(plan_path), "T2", "--output", str(brief_path))
        self.assertEqual(brief_path.read_text(), module.brief(self.plan, "T2"))

    def test_missing_context_and_legacy_rejected(self):
        del self.plan["context"]
        with self.assertRaisesRegex(ValueError, "shared context"):
            self.check()
        self.plan = fixture()
        del self.plan["version"]
        with self.assertRaisesRegex(ValueError, "v2"):
            self.check()

    def test_duplicate_id(self):
        self.plan["tasks"][1]["id"] = "T1"
        with self.assertRaisesRegex(ValueError, "duplicate task"):
            self.check()

    def test_unknown_dependency(self):
        self.plan["tasks"][1]["deps"] = ["T99"]
        with self.assertRaisesRegex(ValueError, "unknown dependency"):
            self.check()

    def test_cycle(self):
        self.plan["tasks"][0]["deps"] = ["T2"]
        with self.assertRaisesRegex(ValueError, "cycle"):
            self.check()

    def test_write_conflict_requires_order(self):
        self.plan["tasks"][1].update(files=["new.ts"], deps=[])
        with self.assertRaisesRegex(ValueError, "write conflict"):
            self.check()
        self.plan["tasks"][1]["deps"] = ["T1"]
        self.check()

    def test_missing_read_without_producer_dependency(self):
        self.plan["tasks"][1]["deps"] = []
        with self.assertRaisesRegex(ValueError, "without prerequisite"):
            self.check()

    def test_missing_shared_instructions(self):
        (self.root / "AGENTS.md").unlink()
        with self.assertRaisesRegex(ValueError, "missing shared context"):
            self.check()

    def test_bad_paths(self):
        for bad in ("../secret", "/tmp/secret", "a/../src.ts", "./src.ts", "a//b", "C:\\secret"):
            with self.subTest(bad=bad):
                self.plan["tasks"][0]["files"] = [bad]
                with self.assertRaises(ValueError):
                    self.check()

    def test_external_symlink_rejected(self):
        (self.root / "outside").symlink_to(self.root.parent, target_is_directory=True)
        self.plan["tasks"][0]["files"] = ["outside/secret"]
        with self.assertRaisesRegex(ValueError, "escapes project"):
            self.check()

    def test_transitive_dependencies(self):
        third = copy.deepcopy(self.plan["tasks"][1])
        third.update(id="T3", files=["new.ts"], deps=["T2"])
        self.plan["tasks"].append(third)
        self.check()

    def test_empty_validation_rejected(self):
        self.plan["context"]["validation"] = []
        with self.assertRaisesRegex(ValueError, "must not be empty"):
            self.check()

    def test_render_deterministic_and_complete(self):
        before = copy.deepcopy(self.plan)
        result = module.render(self.plan)
        self.assertEqual(result, module.render(self.plan))
        self.assertEqual(before, self.plan)
        for expected in ("No network", "Do not change auth", "T1", "T2", "npm test"):
            self.assertIn(expected, result)

    def test_brief_shared_context_without_unrelated_task(self):
        result = module.brief(self.plan, "T2")
        for expected in ("No network", "Do not change auth", "AGENTS.md", "Created by T1", "Test choose()"):
            self.assertIn(expected, result)
        self.assertNotIn("Export choose()", result)
        with self.assertRaisesRegex(ValueError, "unknown task"):
            module.brief(self.plan, "T99")


if __name__ == "__main__":
    unittest.main()
