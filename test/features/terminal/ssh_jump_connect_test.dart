import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

void main() {
  late _Harness h;

  setUp(() => h = _Harness());

  SavedHost bastion({bool forwardAgent = false}) => SavedHost(
    id: 'bastion',
    name: 'Bastion',
    host: 'bastion.example.com',
    port: 2200,
    username: 'jumper',
    authMethod: SshAuthMethod.password,
    password: 'jump-pw',
    connectionTimeoutSeconds: 5,
    forwardAgent: forwardAgent,
  );

  SavedHost target({String? jumpHostId = 'bastion'}) => SavedHost(
    id: 'target',
    name: 'Web',
    host: '10.0.0.5',
    port: 22,
    username: 'deploy',
    authMethod: SshAuthMethod.password,
    password: 'target-pw',
    jumpHostId: jumpHostId,
  );

  group('SshClientFactory jump host', () {
    test('without a jump connects directly', () async {
      final factory = h.factory(hosts: [bastion()]);

      await factory.connect(target(jumpHostId: null));

      expect(h.connections, [('10.0.0.5', 22)]);
      expect(h.clients, hasLength(1));
    });

    test('builds the target client over the jump channel', () async {
      final factory = h.factory(hosts: [bastion()]);

      final client = await factory.connect(target());

      expect(h.connections, [('bastion.example.com', 2200)]);
      expect(h.clients, hasLength(2));
      final jump = h.clients[0];
      final built = h.clients[1];
      expect(identical(client, built), isTrue);
      expect(jump.username, 'jumper');
      expect(built.username, 'deploy');
      expect(jump.forwarded, [('10.0.0.5', 22)]);
      expect(identical(built.socket, jump.channel), isTrue);
    });

    test('verifies each hop host key against that hop', () async {
      final factory = h.factory(hosts: [bastion()]);
      await factory.connect(target());

      await h.clients[0].onVerifyHostKey(
        'ssh-ed25519',
        Uint8List.fromList(utf8.encode('SHA256:jump')),
      );
      await h.clients[1].onVerifyHostKey(
        'ssh-ed25519',
        Uint8List.fromList(utf8.encode('SHA256:target')),
      );

      expect(h.verifier.calls, [
        ('bastion.example.com', 2200, 'SHA256:jump'),
        ('10.0.0.5', 22, 'SHA256:target'),
      ]);
    });

    test('uses each hop credentials', () async {
      final factory = h.factory(hosts: [bastion()]);
      await factory.connect(target());

      expect(h.clients[0].onPasswordRequest!(), 'jump-pw');
      expect(h.clients[1].onPasswordRequest!(), 'target-pw');
    });

    test('never forwards the agent to the jump', () async {
      final jump = bastion(
        forwardAgent: true,
      ).copyWith(authMethod: SshAuthMethod.privateKey, privateKey: 'pem');
      final forwarding = target().copyWith(
        forwardAgent: true,
        authMethod: SshAuthMethod.privateKey,
        privateKey: 'pem',
      );
      final factory = h.factory(
        hosts: [jump],
        keyPairParser: (_, _) => [h.keyPair()],
      );

      await factory.connect(forwarding);

      expect(h.clients[0].agentHandler, isNull);
      expect(h.clients[1].agentHandler, isNotNull);
    });

    test('closes the jump when the target client cannot be built', () async {
      h.failBuildAt = 1;
      final factory = h.factory(hosts: [bastion()]);

      await expectLater(factory.connect(target()), throwsA(isA<StateError>()));

      expect(h.clients.single.closed, isTrue);
    });

    test('closes the jump when the forward channel cannot open', () async {
      h.forwardError = StateError('administratively prohibited');
      final factory = h.factory(hosts: [bastion()]);

      await expectLater(factory.connect(target()), throwsA(isA<StateError>()));

      expect(h.clients.single.closed, isTrue);
    });

    test('closing the target closes the jump', () async {
      final factory = h.factory(hosts: [bastion()]);
      final client = await factory.connect(target());

      client.close();
      await pumpEventQueue();

      expect(h.clients[1].closed, isTrue);
      expect(h.clients[0].closed, isTrue);
    });

    test('a dropped target connection with an error closes the jump', () async {
      final factory = h.factory(hosts: [bastion()]);
      await factory.connect(target());

      h.clients[1].doneCompleter.completeError(StateError('dropped'));
      await pumpEventQueue();

      expect(h.clients[0].closed, isTrue);
    });

    test('fails clearly when the jump host is gone', () async {
      final factory = h.factory(hosts: const []);

      await expectLater(factory.connect(target()), throwsA(isA<AppFailure>()));
      expect(h.connections, isEmpty);
    });

    test('refuses a chained jump', () async {
      final chained = bastion().copyWith(jumpHostId: 'other');
      final factory = h.factory(hosts: [chained]);

      await expectLater(factory.connect(target()), throwsA(isA<AppFailure>()));
      expect(h.connections, isEmpty);
    });
  });
}

class _Harness {
  final connections = <(String, int)>[];
  final clients = <_FakeClient>[];
  final verifier = _RecordingVerifier();
  int? failBuildAt;
  Object? forwardError;

  SSHKeyPair keyPair() {
    final key = ed25519.SigningKey.generate();
    return OpenSSHEd25519KeyPair(
      Uint8List.fromList(key.verifyKey.asTypedList),
      Uint8List.fromList(key.asTypedList),
      'test',
    );
  }

  SshClientFactory factory({
    required List<SavedHost> hosts,
    SshKeyPairParser? keyPairParser,
  }) {
    return SshClientFactory(
      verifier,
      keyPairParser: keyPairParser,
      jumpHostResolver: (id) {
        for (final host in hosts) {
          if (host.id == id) return host;
        }
        return null;
      },
      socketConnector: (host, port, {timeout}) async {
        connections.add((host, port));
        return _FakeSocket();
      },
      clientBuilder:
          (
            socket, {
            required username,
            required identities,
            required agentHandler,
            required onPasswordRequest,
            required onUserInfoRequest,
            required onVerifyHostKey,
          }) {
            if (failBuildAt == clients.length) {
              throw StateError('cannot build client');
            }
            final client = _FakeClient(
              socket,
              username: username,
              agentHandler: agentHandler,
              onPasswordRequest: onPasswordRequest,
              onVerifyHostKey: onVerifyHostKey,
              forwardError: forwardError,
            );
            clients.add(client);
            return client;
          },
    );
  }
}

class _FakeSocket implements SSHSocket {
  final _sink = StreamController<List<int>>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => const Stream.empty();

  @override
  StreamSink<List<int>> get sink => _sink.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
  }
}

class _FakeForwardChannel extends _FakeSocket implements SSHForwardChannel {}

class _FakeClient implements SSHClient {
  _FakeClient(
    this.socket, {
    required this.username,
    required this.agentHandler,
    required this.onPasswordRequest,
    required this.onVerifyHostKey,
    this.forwardError,
  });

  @override
  final SSHSocket socket;
  @override
  final String username;
  @override
  final SSHAgentHandler? agentHandler;
  @override
  final SSHPasswordRequestHandler? onPasswordRequest;
  @override
  final SSHHostkeyVerifyHandler onVerifyHostKey;

  final Object? forwardError;
  final doneCompleter = Completer<void>();
  final forwarded = <(String, int)>[];
  final channel = _FakeForwardChannel();
  bool closed = false;

  @override
  Future<void> get done => doneCompleter.future;

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async {
    forwarded.add((remoteHost, remotePort));
    final error = forwardError;
    if (error != null) throw error;
    return channel;
  }

  @override
  void close() {
    closed = true;
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingVerifier implements HostKeyVerifier {
  final calls = <(String, int, String)>[];

  @override
  Future<bool> verify({
    required String host,
    required int port,
    required String type,
    required String fingerprint,
  }) async {
    calls.add((host, port, fingerprint));
    return true;
  }

  @override
  Future<List<HostKeyRecord>> loadTrustedKeys() async => const [];

  @override
  Future<void> saveTrustedKeys(List<HostKeyRecord> records) async {}

  @override
  Future<void> removeTrustedKey(String host, int port) async {}
}
