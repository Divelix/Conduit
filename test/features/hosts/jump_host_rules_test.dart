import 'package:conduit/features/hosts/domain/jump_host_rules.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  group('jumpHostProblem', () {
    final bastion = buildHost('bastion');

    test('accepts no jump and a plain existing jump', () {
      final target = buildHost('target');

      expect(jumpHostProblem(target, [bastion, target]), isNull);
      expect(
        jumpHostProblem(target.copyWith(jumpHostId: 'bastion'), [
          bastion,
          target,
        ]),
        isNull,
      );
    });

    test('rejects a jump to itself', () {
      final host = buildHost('a').copyWith(jumpHostId: 'a');

      expect(jumpHostProblem(host, [host]), isNotNull);
    });

    test('rejects a dangling reference', () {
      final host = buildHost('a').copyWith(jumpHostId: 'missing');

      expect(jumpHostProblem(host, [host]), isNotNull);
    });

    test('rejects a local jump and a local target', () {
      final local = SavedHost.localShell(id: 'local', name: 'Local');
      final viaLocal = buildHost('a').copyWith(jumpHostId: 'local');
      final localTarget = local.copyWith(jumpHostId: 'bastion');

      expect(jumpHostProblem(viaLocal, [viaLocal, local]), isNotNull);
      expect(jumpHostProblem(localTarget, [localTarget, bastion]), isNotNull);
    });

    test('rejects a chained jump', () {
      final middle = buildHost('middle').copyWith(jumpHostId: 'bastion');
      final target = buildHost('target').copyWith(jumpHostId: 'middle');
      final all = [bastion, middle, target];

      expect(jumpHostProblem(target, all), isNotNull);
    });

    test('rejects giving a jump to a host that is used as a jump', () {
      final target = buildHost('target').copyWith(jumpHostId: 'bastion');
      final bastionWithJump = bastion.copyWith(jumpHostId: 'other');
      final other = buildHost('other');

      expect(
        jumpHostProblem(bastionWithJump, [bastionWithJump, target, other]),
        isNotNull,
      );
    });
  });

  group('eligibleJumpHosts', () {
    test('lists only non-local hosts without a jump, excluding the host', () {
      final host = buildHost('host');
      final plain = buildHost('plain');
      final jumped = buildHost('jumped').copyWith(jumpHostId: 'plain');
      final local = SavedHost.localShell(id: 'local', name: 'Local');

      final eligible = eligibleJumpHosts(host, [host, plain, jumped, local]);

      expect(eligible.map((h) => h.id), ['plain']);
    });

    test('offers nothing to a host that is already used as a jump', () {
      final bastion = buildHost('bastion');
      final target = buildHost('target').copyWith(jumpHostId: 'bastion');
      final other = buildHost('other');

      expect(eligibleJumpHosts(bastion, [bastion, target, other]), isEmpty);
    });
  });

  group('HostsController.remove with jump hosts', () {
    test('blocks deleting a jump host and lists dependents', () async {
      final repository = FakeHostsRepository()
        ..persisted = [
          buildHost('bastion'),
          buildHost('web').copyWith(name: 'Web', jumpHostId: 'bastion'),
          buildHost('db').copyWith(name: 'DB', jumpHostId: 'bastion'),
        ];
      final controller = HostsController(repository);
      await controller.load();

      await controller.remove(buildHost('bastion'));

      expect(controller.hosts, hasLength(3));
      expect(repository.persisted, hasLength(3));
      expect(controller.deleteBlockedMessage, contains('Web'));
      expect(controller.deleteBlockedMessage, contains('DB'));
      expect(controller.errorMessage, isNull);
    });

    test('deletes an unreferenced host and clears a stale message', () async {
      final repository = FakeHostsRepository()
        ..persisted = [
          buildHost('bastion'),
          buildHost('web').copyWith(jumpHostId: 'bastion'),
        ];
      final controller = HostsController(repository);
      await controller.load();
      await controller.remove(buildHost('bastion'));
      expect(controller.deleteBlockedMessage, isNotNull);

      await controller.remove(buildHost('web'));
      await controller.remove(buildHost('bastion'));

      expect(controller.hosts, isEmpty);
      expect(controller.deleteBlockedMessage, isNull);
    });
  });
}
