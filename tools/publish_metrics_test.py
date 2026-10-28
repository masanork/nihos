#!/usr/bin/env python3
"""Exercise publication against local bare remotes, including a concurrent merge."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('publish-metrics.sh').resolve()
FILES = ['history.json', 'code-size.svg', 'coverage.svg', 'summary.md']


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / 'remote.git'
        self.seed = self.root / 'seed'
        self.worker = self.root / 'worker'
        self.other = self.root / 'other'
        self.git(self.root, 'init', '--bare', '--initial-branch=main', str(self.remote))
        self.git(self.root, 'clone', str(self.remote), str(self.seed))
        self.identity(self.seed)
        (self.seed / 'metrics').mkdir()
        for file in FILES:
            (self.seed / 'metrics' / file).write_text('initial\n')
        self.git(self.seed, 'add', '.')
        self.git(self.seed, 'commit', '-m', 'measured source')
        self.git(self.seed, 'push', 'origin', 'main')
        self.source = self.git(self.seed, 'rev-parse', 'HEAD')
        for path in [self.worker, self.other]:
            self.git(self.root, 'clone', str(self.remote), str(path))
            self.identity(path)
        (self.worker / 'metrics/history.json').write_text('new measurements\n')

    def git(self, cwd, *args):
        result = subprocess.run(['git', '-C', str(cwd), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def identity(self, root):
        self.git(root, 'config', 'user.name', 'Test')
        self.git(root, 'config', 'user.email', 'test@example.invalid')

    def advance(self):
        (self.other / 'feature').write_text('new source\n')
        self.git(self.other, 'add', 'feature')
        self.git(self.other, 'commit', '-m', 'new source')
        self.git(self.other, 'push', 'origin', 'main')
        return self.git(self.other, 'rev-parse', 'HEAD')

    def publish(self):
        return subprocess.run(['sh', str(SCRIPT)], cwd=self.worker,
                              env={**os.environ, 'GITHUB_SHA': self.source},
                              capture_output=True, text=True)

    def test_current_source_publishes(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.remote, 'rev-parse', 'main^'), self.source)
        self.assertEqual(self.git(self.remote, 'show', 'main:metrics/history.json'), 'new measurements')

    def test_advanced_main_skips_old_evidence(self):
        latest = self.advance()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.remote, 'rev-parse', 'main'), latest)
        self.assertEqual(self.git(self.worker, 'rev-parse', 'HEAD'), self.source)

    def test_concurrent_push_preserves_new_source(self):
        # The worker's push hook advances main after the freshness check.
        import shlex
        hook = self.worker / '.git/hooks/pre-push'
        other = shlex.quote(str(self.other))
        hook.write_text(f'''#!/bin/sh
set -eu
cd {other}
printf 'new source\\n' > feature
git add feature
git commit -m 'concurrent source'
git push origin main
''')
        hook.chmod(0o755)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('advanced during publication', result.stdout)
        self.assertEqual(self.git(self.remote, 'show', 'main:metrics/history.json'), 'initial')
        self.assertEqual(self.git(self.remote, 'show', 'main:feature'), 'new source')

    def test_unchanged_main_push_failure_is_an_error(self):
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        result = self.publish()
        self.assertEqual(result.returncode, 1)
        self.assertIn('publication failed', result.stderr)
        self.assertEqual(self.git(self.remote, 'rev-parse', 'main'), self.source)


if __name__ == '__main__':
    unittest.main()
