import 'dart:convert';

import 'package:fl_clash/common/mitm_module.dart';
import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';

String _aliasDag(int levels, {bool merge = false}) {
  final source = StringBuffer(
    merge ? 'a0: &a0 {value: kept}\n' : 'a0: &a0 [kept]\n',
  );
  for (var i = 1; i <= levels; i++) {
    final previous = i - 1;
    source.writeln(
      merge
          ? 'a$i: &a$i {<<: [*a$previous, *a$previous]}'
          : 'a$i: &a$i [*a$previous, *a$previous]',
    );
  }
  return source.toString();
}

void main() {
  test('normal aliases keep independent copies and merge precedence', () {
    final document = loadPlainYaml('''
first: &first
  port: 443
  nested: {values: [first]}
second: &second
  port: 80
  enabled: true
left:
  <<: [*first, *second]
  port: 8443
right: *first
''') as Map<String, Object?>;

    final left = document['left']! as Map<String, Object?>;
    final right = document['right']! as Map<String, Object?>;
    expect(left['port'], 8443);
    expect(left['enabled'], true);
    expect(right['port'], 443);
    (left['nested']! as Map<String, Object?>)['values'] = ['changed'];
    expect((right['nested']! as Map<String, Object?>)['values'], ['first']);
    expect(
      ((document['first']! as Map<String, Object?>)['nested']!
          as Map<String, Object?>)['values'],
      ['first'],
    );
  });

  test('ordinary shared aliases below the budget remain valid', () {
    final document = loadPlainYaml(_aliasDag(8)) as Map<String, Object?>;
    var branch = document['a8'];
    for (var i = 0; i < 8; i++) {
      expect(branch, hasLength(2));
      branch = (branch! as List).first;
    }
    expect(branch, ['kept']);
  });

  test('an exponential alias list is rejected before the plain copies', () {
    expect(
      () => loadPlainYaml(_aliasDag(24)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('aliases expand'),
        ),
      ),
    );
  });

  test('repeated merge aliases cannot cause exponential repeated work', () {
    expect(
      () => loadPlainYaml(_aliasDag(24, merge: true)),
      throwsA(isA<FormatException>()),
    );
  });

  test('an alias chain has a bounded plain-conversion depth', () {
    final source = StringBuffer('a0: &a0 [value]\n');
    for (var i = 1; i <= 300; i++) {
      source.writeln('a$i: &a$i [*a${i - 1}]');
    }
    expect(
      () => loadPlainYaml(source.toString()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('nesting'),
        ),
      ),
    );
  });

  test('recursive aliases retain the parser rejection', () {
    expect(
      () => loadPlainYaml('recursive: &recursive [*recursive]'),
      throwsA(isA<FormatException>()),
    );
  });

  test('module detection safely declines a YAML expansion bomb', () {
    final result = parseMitmModule('http: {}\n${_aliasDag(24)}');
    expect(result.isEmpty, isTrue);
    expect(result.resourceUrls, isEmpty);
    expect(result.script, isEmpty);
  });

  test('custom profile import reports an unreadable expansion bomb', () {
    const CustomImportApp app = (
      profileLabels: <String>{},
      profileSources: <ProviderSource, String>{},
      ruleProviderLabels: <String>{},
      ruleProviderSources: <ProviderSource, String>{},
      proxies: <Map<String, dynamic>>[],
      groupNames: <String>{},
    );
    expect(
      () => readCustomProfileImport((
        bytes: utf8.encode('proxies: []\n${_aliasDag(24)}'),
        app: app,
      )),
      throwsA(
        isA<CustomImportException>().having(
          (error) => error.issue,
          'issue',
          CustomImportIssue.unreadable,
        ),
      ),
    );
  });

  test('a large scalar without aliases has no fixed expansion size cap', () {
    final chunk = List.filled(1024, 'x').join();
    final text = List.filled(8193, chunk).join();
    final document = loadPlainYaml('value: $text') as Map<String, Object?>;
    expect(document['value'], text);
  });
}
