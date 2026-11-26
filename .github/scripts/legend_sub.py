"""Serves a directory on loopback the way a panel-less subscription host
does: sub.yaml carries a Subscription-Userinfo header (TB-sized traffic and
an expiry), anything else is a plain file, and /api/... is not there.

Usage: python -I legend_sub.py <directory> <port>
"""

import functools
import http.server
import sys
import time

ROOT, PORT = sys.argv[1], int(sys.argv[2])
TB = 1 << 40


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        if self.path.split('?')[0].endswith('/sub.yaml'):
            expire = int(time.time()) + 40 * 86400
            self.send_header(
                'Subscription-Userinfo',
                f'upload={TB // 20}; download={TB * 13 // 10}; total={2 * TB}; expire={expire}',
            )
        super().end_headers()


http.server.ThreadingHTTPServer(
    ('127.0.0.1', PORT), functools.partial(Handler, directory=ROOT)
).serve_forever()
