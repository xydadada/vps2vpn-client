import html
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SUB = 'https://sub.example.invalid/s/synthetic-token?format=clash&client=fixture'


def summarize(name, text, sub=SUB):
    with tempfile.TemporaryDirectory() as folder:
        pathlib.Path(folder, name).write_text(text, encoding='utf-8')
        done = subprocess.run([sys.executable, '-I', str(HERE / 'summary.py'), folder],
                              env={**os.environ, 'SUB': sub}, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    return done.stdout


class SummaryTest(unittest.TestCase):
    def test_escaped_links_in_failures_are_hidden(self):
        for value in (SUB, html.escape(SUB), SUB.replace('&', '&#38;'),
                      SUB.replace('&', '&#x26;'), SUB.replace('s', '&#115;')):
            with self.subTest(value=value):
                out = summarize('test_result_1.xml',
                                f'<testsuite><failure>AssertionError: {value}</failure></testsuite>')
                self.assertNotIn('synthetic-token', out)
                self.assertNotIn('sub.example.invalid', out)
                self.assertIn('AssertionError: <hidden>', out)

    def test_escaped_links_in_steps_and_logcat_are_hidden(self):
        for name in ('instrumentation.results', 'logcat'):
            with self.subTest(name=name):
                out = summarize(name, f'vps2vpn-testlab NOTE  {html.escape(SUB)}')
                self.assertNotIn('synthetic-token', out)

    def test_a_link_with_entity_text_in_it_is_hidden(self):
        sub = SUB + '&note=&amp;'
        for value in (sub, html.escape(sub)):
            with self.subTest(value=value):
                out = summarize('instrumentation.results', f'NOTE  {value}', sub)
                self.assertNotIn('synthetic-token', out)

    def test_other_text_stays_readable(self):
        out = summarize('instrumentation.results', 'PASS  Connected &amp; ready')
        self.assertIn('PASS  Connected & ready', out)


if __name__ == '__main__':
    unittest.main()
