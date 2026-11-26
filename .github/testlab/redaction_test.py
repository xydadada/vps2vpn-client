import html
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
SUB = 'https://subscription.example.invalid/s/synthetic-token?format=clash&client=fixture'


class SummaryRedaction(unittest.TestCase):
    def summarize(self, filename, text, subscription=SUB):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, filename).write_text(text, encoding='utf-8')
            result = subprocess.run(
                [sys.executable, '-I', str(ROOT / 'summary.py'), directory],
                env={**os.environ, 'SUB': subscription}, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_xml_failure_entities_cannot_expose_the_subscription(self):
        for value in (html.escape(SUB), SUB.replace('&', '&#38;'),
                      SUB.replace('&', '&#x26;'), SUB.replace('s', '&#115;')):
            with self.subTest(encoding=value):
                result = self.summarize(
                    'test_result_fixture.xml',
                    f'<testsuite><failure>AssertionError: {value}</failure></testsuite>',
                )
                self.assertNotIn('synthetic-token', result)
                self.assertNotIn('subscription.example.invalid', result)
                self.assertIn('AssertionError: <hidden>', result)

    def test_instrumentation_and_logcat_labels_decode_before_redaction(self):
        for filename in ('instrumentation.results', 'logcat'):
            with self.subTest(filename=filename):
                result = self.summarize(
                    filename, f'vps2vpn-testlab NOTE  {html.escape(SUB)}',
                )
                self.assertNotIn('synthetic-token', result)
                self.assertIn('NOTE  <hidden>', result)

    def test_unrelated_messages_stay_readable(self):
        result = self.summarize('instrumentation.results', 'PASS  Connected &amp; ready')
        self.assertIn('PASS  Connected & ready', result)

    def test_subscription_with_literal_entity_text_is_still_hidden(self):
        for subscription in (SUB + '&note=&amp;', SUB + '&not=fixture'):
            for value in (subscription, html.escape(subscription)):
                with self.subTest(subscription=subscription, encoding=value):
                    result = self.summarize(
                        'instrumentation.results', f'NOTE  {value}', subscription,
                    )
                    self.assertNotIn('synthetic-token', result)
                    self.assertIn('NOTE  <hidden>', result)

    @unittest.skipUnless(shutil.which('java'), 'needs a JDK')
    def test_android_screen_redactor_on_the_host_jvm(self):
        with tempfile.TemporaryDirectory() as directory:
            source = ROOT / 'driver/src/androidTest/java/com/vps2vpn/testlab/Redaction.java'
            compile_result = subprocess.run(
                ['java', '--module', 'jdk.compiler/com.sun.tools.javac.Main',
                 '-source', '17', '-target', '17', '-d', directory, str(source),
                 str(ROOT / 'tests/RedactionTest.java')], capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run(
                ['java', '-cp', directory, 'com.vps2vpn.testlab.RedactionTest'],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('9 redaction cases passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
