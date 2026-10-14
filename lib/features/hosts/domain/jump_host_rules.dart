import 'package:conduit/features/hosts/domain/saved_host.dart';

/// Why a host's [SavedHost.jumpHostId] cannot be used, or null when it is fine
/// (including when no jump is set). One hop only: a jump host has no jump of
/// its own, and a host that is used as a jump cannot be given one.
String? jumpHostProblem(SavedHost host, List<SavedHost> allHosts) {
  final jumpId = host.jumpHostId;
  if (jumpId == null) {
    return null;
  }
  if (host.isLocal) {
    return 'A local shell cannot use a jump host.';
  }
  if (jumpId == host.id) {
    return 'A host cannot jump through itself.';
  }
  final jump = _byId(allHosts, jumpId);
  if (jump == null) {
    return 'The jump host no longer exists.';
  }
  if (jump.isLocal) {
    return 'A local shell cannot be a jump host.';
  }
  if (jump.jumpHostId != null) {
    return '${jump.name} already uses a jump host; only one hop is supported.';
  }
  if (dependentsOf(host, allHosts).isNotEmpty) {
    return '${host.name} is used as a jump host, so it cannot use one itself.';
  }
  return null;
}

/// Saved hosts that can be picked as the jump host for [host].
List<SavedHost> eligibleJumpHosts(SavedHost host, List<SavedHost> allHosts) {
  if (host.isLocal || dependentsOf(host, allHosts).isNotEmpty) {
    return const [];
  }
  return [
    for (final candidate in allHosts)
      if (candidate.id != host.id &&
          !candidate.isLocal &&
          candidate.jumpHostId == null)
        candidate,
  ];
}

/// Hosts that name [host] as their jump host.
List<SavedHost> dependentsOf(SavedHost host, List<SavedHost> allHosts) {
  return [
    for (final other in allHosts)
      if (other.id != host.id && other.jumpHostId == host.id) other,
  ];
}

SavedHost? _byId(List<SavedHost> hosts, String id) {
  for (final host in hosts) {
    if (host.id == id) {
      return host;
    }
  }
  return null;
}
