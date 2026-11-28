import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

YamlMap _workflow(String name) =>
    loadYaml(File('.github/workflows/$name.yaml').readAsStringSync())
        as YamlMap;

void main() {
  test('source checks can be called at the build commit without secrets', () {
    final workflow = _workflow('verify');
    final triggers = workflow['on'] as YamlMap;

    expect(triggers.containsKey('workflow_call'), isTrue);
    expect(triggers['workflow_call'], isNull);
    expect(workflow['permissions'], {'contents': 'read'});
    final concurrency = workflow['concurrency'] as YamlMap;
    expect(concurrency['group'], startsWith('verify-'));
    expect(concurrency['group'], contains(r'github.workflow'));
    expect(concurrency['group'], contains(r'github.run_id'));
  });

  for (final (workflowName, buildJob) in [
    ('vps2vpn', 'windows'),
    ('android', 'build'),
  ]) {
    test('$workflowName requires all checks before package and signing', () {
      final workflow = _workflow(workflowName);
      final jobs = workflow['jobs'] as YamlMap;
      final verify = jobs['verify'] as YamlMap;
      final build = jobs[buildJob] as YamlMap;

      expect(verify['uses'], './.github/workflows/verify.yaml');
      expect(verify['permissions'], {'contents': 'read'});
      expect(verify.containsKey('secrets'), isFalse);
      expect(verify.containsKey('if'), isFalse);
      expect(build['needs'], 'verify');
      expect(build.containsKey('if'), isFalse);
      expect(build.containsKey('continue-on-error'), isFalse);
      expect((workflow['on'] as YamlMap).keys, ['workflow_dispatch']);

      final steps = (build['steps'] as YamlList).cast<YamlMap>();
      final fetch = steps.singleWhere(
        (step) => step['name'] == 'Flutter dependencies',
      );
      expect(fetch['run'], contains('flutter pub get --enforce-lockfile'));
      expect(steps.any((step) => step['name'] == 'Package'), isTrue);
      final publish = steps.singleWhere(
        (step) => step['name'] == 'Sign and upload the pre-release',
      );
      expect(publish['if'], r'${{ inputs.publish }}');
    });
  }
}
