import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


GENERATOR = Path(__file__).resolve().parents[1] / "codex-channel-unit.py"
THREAD = "01a0d900-37e8-7480-8fc4-17b6c0724f7c"


class ChannelUnitTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.binary = self.directory / 'receiver % $ " test'
        self.binary.touch()
        self.output = self.directory / "units"
        self.unit = self.output / ("paranoia-codex-" + THREAD + ".service")

    def generate(self, topic="Тема", thread=THREAD, env_thread=None):
        env = os.environ.copy()
        env.pop("CODEX_THREAD_ID", None)
        if env_thread is not None:
            env["CODEX_THREAD_ID"] = env_thread
        command = [sys.executable, str(GENERATOR), "--topic", topic,
                   "--after-message", "handled-message", "--binary", str(self.binary),
                   "--output-dir", str(self.output)]
        if thread is not None:
            command += ["--thread", thread]
        return subprocess.run(command, env=env, capture_output=True, text=True)

    def test_literal_arguments(self):
        result = self.generate(topic='Тема %n $HOME "тест"\nстрока')
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.unit.read_text()
        self.assertIn('ExecStart=:', content)
        self.assertIn('"Тема %%n $HOME \\"тест\\"\\nстрока"', content)
        self.assertIn('receiver %% $ \\" test', content)
        self.assertIn('"--thread" "' + THREAD + '"', content)
        self.assertIn("systemctl --user enable --now ", result.stdout)

    def test_current_thread_from_environment(self):
        result = self.generate(thread=None, env_thread=THREAD)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.unit.is_file())

    def test_existing_unit_is_not_replaced(self):
        self.assertEqual(self.generate().returncode, 0)
        original = self.unit.read_bytes()
        self.assertNotEqual(self.generate(topic="Другая").returncode, 0)
        self.assertEqual(self.unit.read_bytes(), original)

    def test_invalid_binding(self):
        for values in ({"thread": None}, {"thread": "../other"}, {"topic": " "}):
            with self.subTest(values=values):
                self.assertNotEqual(self.generate(**values).returncode, 0)
                self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
