# Public TLS test material

These localhost-only fixtures are public test data from the Dart SDK:

- [localhost.crt](https://github.com/dart-lang/sdk/blob/main/tests/standalone/io/localhost.crt), Git blob `eeab89071c11b96699029c13dc0db5f083b40543`.
- [localhost.key](https://github.com/dart-lang/sdk/blob/main/tests/standalone/io/localhost.key), Git blob `20815e4af6eb750fd6edd40eb0aabb01eb4b43d5`.

The key is publicly known and belongs only in tests. The fixtures are used by `panel_tls_test.dart` to exercise a real TLS handshake, exact certificate pin matching, and rejection before any token-bearing HTTP request is sent. They are not app assets or deployed credentials.
