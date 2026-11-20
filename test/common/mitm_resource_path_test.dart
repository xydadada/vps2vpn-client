import 'package:fl_clash/common/backup.dart';
import 'package:fl_clash/common/mitm_module.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = '''
[Map Local]
^https://example.com/a data="body.json"
[Script]
example = type=http-response,pattern=^https://example.com,script-path=script.js
[Rule]
DOMAIN-SET,list.conf,REJECT
''';
  const unsafeNames = [
    '../ca.key',
    r'..\ca.key',
    '/etc/passwd',
    r'C:\secret.txt',
    'body.json:secret',
    'NUL',
    'COM1.txt',
    'LPT².js',
    'name.',
    'name ',
    'line\nbreak',
    '',
  ];

  test('restored mappings never put an unsafe path in Core configuration', () {
    for (final name in unsafeNames) {
      final parsed = parseMitmModule(
        source,
        resources: {'body.json': name, 'script.js': name, 'list.conf': name},
      );
      expect(parsed.mapLocal, isEmpty, reason: name);
      expect(parsed.script, isEmpty, reason: name);
      expect(parsed.ruleProviders, isEmpty, reason: name);
      expect(parsed.skipped, hasLength(3), reason: name);
    }
  });

  test('ordinary stored basenames retain all three supported resources', () {
    final parsed = parseMitmModule(
      source,
      resources: const {
        'body.json': 'abc123.json',
        'script.js': 'def456.js',
        'list.conf': 'abc-def.conf',
      },
    );
    expect(parsed.mapLocal, hasLength(1));
    expect(parsed.script, hasLength(1));
    expect(parsed.ruleProviders, hasLength(1));
    expect(parsed.skipped, isEmpty);
  });

  test('backup attachment enumeration rejects unsafe restored mappings', () {
    final module = MitmModule(
      id: 1,
      name: 'Local',
      lastUpdateTime: DateTime(2026),
      resources: {
        for (final (index, name) in unsafeNames.indexed) '$index.js': name,
        'safe.js': 'abc.js',
      },
    );
    expect(mitmAttachments(module), {'safe.js': 'abc.js'});
    expect(
      BackupEntries.of(
        profileIds: const [],
        scriptIds: const [],
        providers: const [],
        mitmModules: [module],
      ).where((entry) => entry.contains('/resources/')),
      [BackupEntries.mitmResource('abc.js')],
    );
  });
}
