# Feature idea: ProxyJump (jump host) for saved hosts

Status: Draft. Not started. Keep it as a single feature MR.

## Problem

Some machines can't be reached directly from the phone. They sit behind a bastion, a home router, or a private
network, and the only thing that can reach them is another SSH host. Today a saved host has one address and one
port. A user who needs to reach such a machine has to either expose it, or open a shell on the bastion and type
`ssh` again by hand. Neither is good on a phone keyboard.

OpenSSH already solves this with `ProxyJump` (`ssh -J`). Conduit users who keep an `~/.ssh/config` know the
feature; phone users have no equivalent.

## Proposed behavior

- A saved host gets an optional **Jump host** field. It points at another saved host, chosen from a list.
- Connecting to a host with a jump first connects to the jump host, then opens a TCP channel from it to the target,
  then runs the normal SSH handshake to the target over that channel.
- Each hop has its own auth and its own host-key check. The jump host uses its own saved credentials, not the
  target's. Both fingerprints go through the existing trust flow.
- The host card and the terminal tab show the route, for example "via bastion".
- Errors name the hop that failed: "Jump host 'bastion' refused the connection" versus "Target 'web-1' timed out
  through bastion". Don't reuse the target's error text for both.
- Connection timeout applies to each hop separately.

## Scope for the first MR

- One jump, no chains. Saved hosts can only point at a host that has no jump of its own, so the code path stays one
  level deep. Chains can come later as a list.
- SSH and SFTP both use the same connect path, so both get the jump for free. Check SFTP in the test plan.
- Mosh: out of scope for v1. Mosh bootstraps over SSH, so it can reuse the jump only after the bootstrap path is
  reviewed. Show the jump field as disabled for Mosh hosts with a short note.
- Agent forwarding through a jump: leave it as it is for the target. Document it, don't change it.

## Implementation notes (to verify before coding)

- `lib/features/terminal/data/ssh_client_factory.dart`, `connect()`, creates one `SSHClient` over a
  `TcpSshSocket`. The idea: when `host.jumpHostId` is set, build the jump `SSHClient` the same way, then open a
  channel with `forwardLocal(targetHost, targetPort)` and pass that channel to the target `SSHClient` as its socket.
- Check in the `dartssh2_conduit` fork that the forward channel can be used as an `SSHSocket`. If not, a small
  adapter is needed.
- The jump connection must be closed when the target connection closes. Track both in one object so a failed
  target does not leave the jump open.
- `lib/features/hosts/domain/saved_host.dart`: add a nullable `jumpHostId`. Old backups have no such field, so
  default it to null in `fromJson`. Export/import (`backup`) must round-trip it.
- Deleting a saved host that is a jump for others: block the delete with a message listing the hosts that use it,
  or clear their jump. Pick one and say which in the MR.
- Host keys for the jump host are trusted the same way as any other host. Don't add a separate trust store.

## Tests to add

- Unit: `connect()` with a jump builds the target over the jump channel (use a fake `SSHSocket`, as the existing
  factory tests do).
- Unit: `SavedHost` JSON round-trip with and without `jumpHostId`; an old backup without the field loads.
- Unit: delete guard for a host that is a jump.
- Manual: a bastion with a target that is only reachable from it, on Android and iOS. Check a dropped jump, a wrong
  host key on each hop, and a wrong password on the jump.

## Open questions for the maintainer

- Store the jump as a reference to a saved host (updates flow through), or copy its address and credentials?
  Reference is the proposal above; copying avoids the delete guard.
- Should the jump show in the host list as its own card, or only in the form?
- Is one hop enough for the first release, or should chains be in v1?
