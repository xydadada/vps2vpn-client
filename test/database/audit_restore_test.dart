import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Iterable<T> _failAfter<T>(T item) sync* {
  yield item;
  throw StateError('broken input');
}

void main() {
  late Database database;

  setUp(() {
    database = Database(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> seedBackupTables() async {
    await database.restore(
      const [Profile(id: 1, autoUpdateDuration: Duration.zero)],
      [Script(id: 2, label: 'Kept', lastUpdateTime: DateTime(2026))],
      const [Rule(id: 3, profileId: 1, content: 'example.com')],
      const [DisabledRule(profileId: 1, ruleId: 3)],
      const [
        ProxyGroup(
          id: 4,
          profileId: 1,
          name: 'Kept',
          type: GroupType.Selector,
          proxies: ['DIRECT'],
        ),
      ],
      clashProviders: const [ClashProvider(id: 5, label: 'Kept')],
      customProxies: const [
        CustomProxy(id: 6, definition: {'name': 'Kept', 'type': 'direct'}),
      ],
      proxyDialers: const [
        ProxyDialer(profileId: 1, proxyId: 6, target: 'DIRECT'),
      ],
      mitmModules: [
        MitmModule(id: 7, name: 'Kept', lastUpdateTime: DateTime(2026)),
      ],
    );
  }

  Future<List<int?>> backupCounts() async => [
    for (final table in <TableInfo>[
      database.profiles,
      database.scripts,
      database.rules,
      database.disabledRules,
      database.proxyGroups,
      database.clashProviders,
      database.customProxies,
      database.proxyDialers,
      database.mitmModules,
    ])
      await table.count.getSingle(),
  ];

  test('an empty override restore clears every backed-up table', () async {
    await seedBackupTables();
    expect(await backupCounts(), List.filled(9, 1));

    await database.restore(
      const [],
      const [],
      const [],
      const [],
      const [],
      isOverride: true,
    );

    expect(await backupCounts(), List.filled(9, 0));
    expect(
      await database.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
    );
  });

  test('an empty compatible restore leaves existing records intact', () async {
    await seedBackupTables();

    await database.restore(const [], const [], const [], const [], const []);

    expect(await backupCounts(), List.filled(9, 1));
    expect((await database.profilesDao.query().get()).single.id, 1);
    expect((await database.scriptsDao.query().get()).single.label, 'Kept');
  });

  test('batch replacement propagates input failures and rolls back', () async {
    const kept = CustomProxy(id: 1, definition: {'name': 'Kept'});
    const incoming = CustomProxy(id: 2, definition: {'name': 'Partial'});
    await database.customProxies.put(kept.toCompanion());

    await expectLater(
      database.transaction(() async {
        await database.customProxies.put(
          kept.copyWith(definition: {'name': 'Must roll back'}).toCompanion(),
        );
        await database.batch((batch) {
          database.customProxies.setAll(
            batch,
            _failAfter(incoming.toCompanion()),
            deleteFilter: (_) => const Constant(true),
            preDelete: true,
          );
        });
      }),
      throwsStateError,
    );

    final rows = await database.select(database.customProxies).get();
    expect(rows.map((row) => row.id), [1]);
    expect(rows.single.definition, kept.definition);
  });

  test(
    'script bulk insert never commits a partially enumerated input',
    () async {
      final kept = Script(id: 1, label: 'Kept', lastUpdateTime: DateTime(2026));
      final incoming = kept.copyWith(id: 2, label: 'Partial');
      await database.scripts.put(kept.toCompanion());

      await expectLater(
        database.scriptsDao.putAll(_failAfter(incoming.toCompanion())),
        throwsStateError,
      );

      expect(await database.scriptsDao.query().get(), [kept]);
    },
  );

  test('script replacement reports an input failure to its caller', () async {
    final kept = Script(id: 1, label: 'Kept', lastUpdateTime: DateTime(2026));
    await database.scripts.put(kept.toCompanion());

    await expectLater(
      database.scriptsDao.setAll(_failAfter(kept.copyWith(id: 2))),
      throwsStateError,
    );

    expect(await database.scriptsDao.query().get(), [kept]);
  });

  test('an invalid row cannot partially replace a backup', () async {
    await seedBackupTables();

    await expectLater(
      database.restore(
        const [Profile(id: 100, autoUpdateDuration: Duration.zero)],
        const [],
        const [],
        const [],
        const [],
        customProxies: [
          CustomProxy(id: 101, definition: {'invalid': Object()}),
        ],
        isOverride: true,
      ),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );

    expect(await backupCounts(), List.filled(9, 1));
    expect((await database.profilesDao.query().get()).single.id, 1);
    expect((await database.customProxiesDao.query().get()).single.id, 6);
  });
}
