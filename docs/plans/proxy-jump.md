# Plan: proxy-jump

- Started: 2026-10-14
- Cycle item: housekeeping
- Branch: `feat/proxy-jump`
- Idea (verbatim from the human): see `docs/ideas/proxy-jump.md`
  (ProxyJump / jump host for saved hosts)

## Goal
A saved host can name another saved host as its **Jump host**. Connecting to it
(SSH terminal and SFTP) first opens an SSH connection to the jump host, opens a
`forwardLocal` channel from it to the target, and runs the normal SSH handshake
to the target over that channel. Each hop uses its own saved credentials, its
own connection timeout and its own host-key check through the existing trust
flow. Errors name the hop that failed. The host card and terminal tab show
"via <jump name>". Backups round-trip the field and old backups still load.
Shipped as a single MR.

## Non-goals
- Chains of jumps. A jump host must itself have no jump (one level only).
- Mosh over a jump. The jump field is shown disabled for Mosh hosts with a
  short note; the Mosh bootstrap path is not touched.
- Local-shell hosts (`isLocal`) as target or as jump.
- Changing agent forwarding. It stays as is for the target; document only.
- A separate host-key trust store, or showing the jump as its own card in the
  host list.

## Design deltas
- `lib/features/hosts/domain/saved_host.dart`: nullable `jumpHostId`
  (field, `copyWith` with a clear flag, `toJson`, `fromJson` defaulting to
  null). Validity rules for the jump reference live in a small pure helper
  next to `SavedHost`, not in `isValid`, because they need the host list.
- `lib/features/terminal/data/ssh_client_factory.dart`: `connect()` resolves the
  jump host, builds the jump `SSHClient`, opens `forwardLocal`, and hands the
  channel to the target `SSHClient` as its socket. Returned object must own both
  clients so closing the target closes the jump.
- `lib/features/hosts/presentation/`: hosts controller (delete guard), form
  (field), card (route label).
- `lib/features/terminal/data/ssh_error_formatter.dart` and the two repositories
  that call the factory (`dart_ssh_terminal_repository.dart`,
  `dart_ssh_sftp_repository.dart`): hop-aware error text.
- Decision: **reference, not copy** (the idea's proposal). Consequence is the
  delete guard in step 2. Decision on guard: **block the delete** and list the
  dependent hosts. Record both in the MR description; no ADR needed.

## Steps
- [x] **Step 1 (D1) — `jumpHostId` on `SavedHost` and backup round-trip.**
  Add the field, `copyWith(jumpHostId, clearJumpHostId)`, `toJson`, `fromJson`
  (missing key → null). Check `lib/features/backup/data/app_backup_service.dart`
  and `secure_saved_hosts_repository.dart` pass it through untouched.
  Test: `test/features/hosts/hosts_test.dart` JSON round-trip with and without
  the field; `test/features/backup/app_backup_service_test.dart` export/import
  keeps it and an old backup without it loads with null.
- [x] **Step 2 (D2) — Jump reference rules and delete guard.**
  Pure helper: a jump is valid only if the target exists, is not the host
  itself, is not local, and has no `jumpHostId` of its own; a host that is used
  as a jump cannot itself be given a jump. `HostsController.remove` refuses
  when other hosts reference the host, sets an error message listing their
  names, and leaves state unchanged; `hosts_page.dart` (around line 654)
  surfaces it. Test: guard blocks and lists names; unreferenced host still
  deletes; helper rejects self, chained, local and dangling references.
- [x] **Step 3 (D3) — Connect through the jump.**
  First verify, in the pinned `dartssh2_conduit` fork
  (`c39f316a…`, fetch with `flutter pub get`), that the `forwardLocal` channel
  can be used as an `SSHSocket`; if not, add a small adapter beside
  `tcp_ssh_socket.dart`. Give `SshClientFactory` a way to resolve a jump host
  by id (injected lookup; the three repositories currently build the factory
  per call, so check how they can receive it). In `connect()`: connect and
  authenticate the jump with its own `SavedHost` (own timeout, own
  `onVerifyHostKey` against the jump's address and port), `forwardLocal` to the
  target, build the target `SSHClient` on the channel with the target's own
  auth and host-key check. Return a wrapper that closes the target and then the
  jump, and closes the jump if any later step fails. Test with a fake
  `SSHSocket` as the existing factory tests do: target is built over the jump
  channel, both fingerprints are verified against the right host, a failure in
  the target closes the jump, closing the session closes both. This is the D3
  step: the fork's API and close ordering are not known until it runs.
- [ ] **Step 4 (D2) — Hop-aware errors.**
  Tag failures with the hop (jump or target) at the point they are thrown in
  the factory, and have `describeSshConnectionError` and the two repository
  `AppFailure` messages use it: "Jump host 'bastion' refused the connection",
  "Target 'web-1' timed out through bastion". Do not reuse the target's text
  for the jump. Test: refused/timeout/auth-fail/host-key-reject on each hop
  produce distinct messages naming the right host.
- [ ] **Step 5 (D2) — UI: form field, card and tab route label.**
  `host_form_page.dart`: **Jump host** dropdown of eligible saved hosts (from
  the step 2 helper) plus "None"; disabled with a one-line note when Mosh is
  on, and turning Mosh on clears the jump. `host_card.dart` and the terminal
  tab title show "via <name>". Widget tests: dropdown lists only eligible
  hosts, saving stores the id, Mosh disables it, card shows the label.
- [ ] **Step 6 (D1) — Docs and manual verification.**
  Document the feature, the agent-forwarding behaviour, and the Mosh
  limitation (see *Docs to update*). Run the manual matrix from the idea file.

## Acceptance
```
flutter analyze   # No issues found
flutter test      # all tests pass, including the new jump tests
```
Plus the manual run on Android and iOS: a bastion with a target reachable only
from it. Check terminal and SFTP, a dropped jump connection, a wrong host key on
each hop, and a wrong password on the jump (error names the jump).

## Attested GPU run
Not applicable (no `scene/`, `simloop`, `teleop/` or WBC code touched).

## Tuned constants touched
None. (Default per-hop timeout stays `connectionTimeoutSeconds`, 12 s.)

## Docs to update on completion
- `docs/ideas/proxy-jump.md` — delete, or mark as shipped, once this plan is
  retired.
- README / user docs — a short "Jump host" section: one hop, per-hop
  credentials, Mosh unsupported, agent forwarding applies to the target only.
- MR description — state the reference-not-copy and block-delete decisions.

Written at planning time while the deltas are fresh.

## Open questions
- ⚠ OPEN: Reference vs copy of the jump's address and credentials. Plan assumes
  reference. Human decides, before step 1.
- ⚠ OPEN: Jump shown as its own host-list card, or only in the form? Plan
  assumes form only (no list change). Human decides, before step 5.
- ⚠ OPEN: One hop enough for v1? Plan assumes yes. Human decides, before step 1.
- ⚠ OPEN: Does the `dartssh2_conduit` `forwardLocal` channel implement
  `SSHSocket`? Agent answers in step 3; if an adapter is needed, say so in the
  MR.
  **Answered (step 3):** yes, `SSHForwardChannel` implements `SSHSocket`; no
  adapter needed.
- ⚠ OPEN: How the factory gets the host list for jump lookup (injected
  resolver vs passing the resolved jump `SavedHost` into `connect`). Agent
  decides in step 3.
  **Answered (step 3):** injected `JumpHostResolver` (`SavedHost? Function(String id)`),
  passed to the factory by the two repositories and wired in `main.dart` from
  `HostsController.hosts`.
- ⚠ OPEN: Delete behaviour is **block**, per this plan; human may prefer
  "clear dependents' jump". Decide before step 2.
