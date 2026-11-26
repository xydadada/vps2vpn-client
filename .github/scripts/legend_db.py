"""Reads or sets what the app's database holds for its one subscription:
the node picked in each group, and the traffic the server reported.

Usage: python -I legend_db.py <database.sqlite> get
       python -I legend_db.py <database.sqlite> set <group> <node> ...
"""

import json
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
columns = [row[1] for row in db.execute('PRAGMA table_info(profiles)')]
rows = db.execute('SELECT * FROM profiles').fetchall()
if len(rows) != 1:
    sys.exit(f'expected one subscription, found {len(rows)}')
profile = dict(zip(columns, rows[0]))
if sys.argv[2] == 'set':
    picked = json.loads(profile['selected_map'] or '{}')
    pairs = sys.argv[3:]
    picked.update(zip(pairs[::2], pairs[1::2]))
    db.execute(
        'UPDATE profiles SET selected_map = ? WHERE id = ?',
        (json.dumps(picked, ensure_ascii=False), profile['id']),
    )
    db.commit()
    profile['selected_map'] = json.dumps(picked, ensure_ascii=False)
print(json.dumps({
    'selected': json.loads(profile['selected_map'] or '{}'),
    'traffic': profile.get('subscription_info'),
}, ensure_ascii=False))
