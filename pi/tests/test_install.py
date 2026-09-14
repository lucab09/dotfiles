import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / "install-workflow.sh"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.target = Path(self.temp.name) / "agent"
        self.target.mkdir()
        self.claude = Path(self.temp.name) / "claude profile"

    def install(self, *args, **env):
        return subprocess.run(["bash", str(INSTALLER), *args], capture_output=True, text=True,
                              env={**os.environ, "PI_CODING_AGENT_DIR": str(self.target),
                                   "CLAUDE_CONFIG_DIR": str(self.claude), **env})

    def test_backup_idempotence_and_preserved_config(self):
        build = self.target / "skills/build"
        build.mkdir(parents=True)
        (build / "SKILL.md").write_text("old skill")
        (build / "config.json").write_text('{"model":"keep"}')
        first = self.install()
        self.assertEqual(first.returncode, 0, first.stderr)
        files = sorted(p.relative_to(self.target) for p in self.target.rglob("*"))
        second = self.install()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(files, sorted(p.relative_to(self.target) for p in self.target.rglob("*")))
        self.assertEqual((build / "config.json").read_text(), '{"model":"keep"}')
        backups = list((self.target / "backups").glob("*/skills/build/SKILL.md"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "old skill")
        self.assertTrue((self.target / "skills/plan/../../workflow/plan.py").is_file())

    def test_directory_symlink_rejected_before_any_mutation(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (self.target / "skills").symlink_to(outside, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.target / "extensions").exists())

    def test_file_symlink_backed_up_without_overwriting_original(self):
        outside = Path(self.temp.name) / "external.ts"
        outside.write_text("keep external file")
        extensions = self.target / "extensions"
        extensions.mkdir()
        (extensions / "decision-selector.ts").symlink_to(outside)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outside.read_text(), "keep external file")
        self.assertFalse((extensions / "decision-selector.ts").is_symlink())

    def test_claude_only_adapts_skills_without_installing_pi_ui(self):
        result = self.install("--target", "claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.target.iterdir()), [])
        self.assertFalse((self.claude / "extensions").exists())
        for name, command in (("brainstorm", "brainstorm"), ("plan", "workflow-plan"), ("build", "build")):
            skill = self.claude / f"skills/{command}/SKILL.md"
            content = skill.read_text()
            self.assertIn(f"name: {command}\n", content)
            self.assertIn("`AskUserQuestion`", content)
            self.assertNotIn("`ask_user`", content)
            self.assertNotIn("/skill:", content)
            self.assertNotIn("<skill-directory>", content)
            # No duplicated hand-authored Claude workflow: reverse the adapter.
            original = (INSTALLER.parent / f"skills/{name}/SKILL.md").read_text()
            restored = (content.replace("`AskUserQuestion`", "`ask_user`")
                        .replace("/workflow-plan", "/skill:plan")
                        .replace("${CLAUDE_SKILL_DIR}", "<skill-directory>")
                        .replace("name: workflow-plan\n", "name: plan\n"))
            self.assertEqual(restored, original)
        self.assertIn("/workflow-plan", (self.claude / "skills/brainstorm/SKILL.md").read_text())
        self.assertFalse((self.claude / "skills/plan/SKILL.md").exists())
        self.assertTrue((self.claude / "skills/plan/.workflow-managed").is_file())

    def test_claude_migration_backs_up_legacy_plan_and_sync_markers(self):
        for name in ("brainstorm", "plan", "build"):
            directory = self.claude / "skills" / name
            directory.mkdir(parents=True)
            (directory / "SKILL.md").write_text(f"old {name}")
            (directory / ".pi-synced").write_text("old sync marker")
        (self.claude / "skills/build/config.json").write_text("keep model config")
        (self.claude / "settings.json").write_text("keep settings")
        result = self.install("--target", "claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list((self.claude / "backups").iterdir())
        self.assertEqual(len(backups), 1)
        for name in ("brainstorm", "plan", "build"):
            directory = self.claude / "skills" / name
            self.assertTrue(directory.is_dir())
            self.assertFalse((directory / ".pi-synced").exists())
            self.assertEqual((backups[0] / f"skills/{name}/SKILL.md").read_text(), f"old {name}")
            self.assertEqual((backups[0] / f"skills/{name}/.pi-synced").read_text(), "old sync marker")
            # The old sync script skips existing destinations without .pi-synced.
        self.assertEqual((self.claude / "skills/build/config.json").read_text(), "keep model config")
        self.assertEqual((self.claude / "settings.json").read_text(), "keep settings")

    def test_all_is_idempotent_and_helpers_are_identical(self):
        first = self.install("--target", "all")
        self.assertEqual(first.returncode, 0, first.stderr)
        before = sorted(p.relative_to(self.temp.name) for p in Path(self.temp.name).rglob("*"))
        second = self.install("--target", "all")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(before, sorted(p.relative_to(self.temp.name) for p in Path(self.temp.name).rglob("*")))
        self.assertEqual((self.target / "workflow/plan.py").read_bytes(), (self.claude / "workflow/plan.py").read_bytes())

    def test_all_preflights_claude_before_mutating_pi(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        self.claude.mkdir()
        (self.claude / "skills").symlink_to(outside, target_is_directory=True)
        result = self.install("--target", "all")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)
        self.assertEqual(list(self.target.iterdir()), [])
        self.assertEqual(list(outside.iterdir()), [])

    def test_overlapping_harness_directories_rejected(self):
        result = self.install("--target", "all", CLAUDE_CONFIG_DIR=str(self.target))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not overlap", result.stderr)
        self.assertEqual(list(self.target.iterdir()), [])

    def test_unknown_target_rejected(self):
        result = self.install("--target", "typo")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.target.iterdir()), [])

    def test_installed_claude_helper_runs_from_another_cwd_with_spaces(self):
        from test_plan import fixture
        result = self.install("--target", "claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        project = Path(self.temp.name) / "sample project"
        (project / ".pi").mkdir(parents=True)
        (project / ".pi/plan.json").write_text(json.dumps(fixture()))
        for name in ("AGENTS.md", "src.ts"):
            (project / name).write_text("source")
        skill_dir = self.claude / "skills/workflow-plan"
        content = (skill_dir / "SKILL.md").read_text()
        commands = [line for line in content.splitlines() if line.startswith("python3 ")]
        self.assertEqual(len(commands), 2)
        for command in commands:
            expanded = command.replace("${CLAUDE_SKILL_DIR}", str(skill_dir))
            check = subprocess.run(["bash", "-c", expanded], cwd=project, capture_output=True, text=True)
            self.assertEqual(check.returncode, 0, check.stderr)
        self.assertTrue((project / ".pi/plan.md").is_file())
        self.assertIn("No network", (project / ".pi/plan.md").read_text())


if __name__ == "__main__":
    unittest.main()
