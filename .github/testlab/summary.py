"""Prints what one Test Lab phone saw, with the subscription, its host and
every address blanked. Usage: summary.py <device results dir>; the link comes
from the SUB environment variable."""

import html
import os
import pathlib
import re
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1])
sub = os.environ.get('SUB', '')
secrets = [s for s in (sub, sub.encode().hex(), urllib.parse.quote(sub, safe=''),
                       urllib.parse.urlsplit(sub).hostname if sub else '') if s]


def scrub(text):
    # Test reports are XML, so the link may arrive as &amp; or &#38;.
    text = html.unescape(text)
    for secret in secrets:
        text = text.replace(secret, '<hidden>').replace(html.unescape(secret), '<hidden>')
    text = re.sub(r'\b\d{1,3}(\.\d{1,3}){3}\b', 'x.x.x.x', text)
    return re.sub(r'(?i)\b[0-9a-f]{1,4}(:[0-9a-f]{0,4}){3,7}\b', 'x:x::x', text)


def lines(pattern, keep, last=False):
    found = []
    for path in sorted(root.rglob(pattern)):
        found += [l for l in path.read_text(errors='replace').splitlines() if keep.search(l)]
    return found[-120:] if last else found[:120]


steps = re.compile(r'PASS |NOTE |INSTRUMENTATION_STATUS: stack=|AssertionError|Exception')
crash = re.compile(r'FATAL EXCEPTION|AndroidRuntime|ANR in|vps2vpn-testlab|com\.vps2vpn\.client')
print('-- steps')
print(scrub('\n'.join(lines('instrumentation.results', steps))))
print('-- failures')
for path in sorted(root.rglob('test_result_*.xml')):
    for failure in re.findall(r'<failure[^>]*>(.{0,2000}?)</failure>', path.read_text(errors='replace'), re.S):
        print(scrub(failure))
print('-- logcat')
print(scrub('\n'.join(lines('logcat', crash, last=True))))
