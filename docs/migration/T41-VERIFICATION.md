# T41 verification — bounded downloads, cancellation and safe restart

The Mobile download controller runs **one active job** and accepts at most
**three waiting jobs**. Requests for the same Pack share an existing active/queued
job. The next explicit request waits until transfer, verification, atomic install
and local projection of the preceding job finish. Overflow reports a queue-full
error. There is no unbounded queue or automatic retry.

Pack actions show **Queued** or **Progress** so the sheet can be reopened without
starting duplicate work. Both active and queued jobs can be cancelled; Retry is
manual. Queued cancellation starts no request. Active cancellation aborts HTTP,
removes partial private bytes and checks cancellation again during verification
and before activation. Once the atomic pointer rename starts, installation wins;
the client reports the installed result rather than claiming it rolled back.
Closing a sheet leaves its explicit job running while the app stays open. Disposing
the owning scope cancels active/waiting work.

## Interrupted requests and bounded private cleanup

Recovery deliberately restarts downloads from byte zero. Waiting jobs are not
persisted or automatically resumed after restart. A fresh Download/Retry checks the
current public descriptor, trust pins, signature, hashes and sizes again. App
startup performs only local cleanup; it creates no HTTP client or catalog request.

Each private `download-*` staging directory has an OS file-lock lease, plus a
canonical path guard for jobs in the owning isolate. Recovery under the store's
writer lock skips live transfers, including another process's lease. It reclaims
at most eight abandoned temporary entries per pass. Remaining entries are left for
the next startup or explicit download. Cleanup errors do not hide valid installed
content. Directory names are validated and filesystem traversal does not follow
symbolic links. Images remain beneath application-private Pack storage.

The store writes and verifies `active.pending` before renaming staged content to
its immutable generation name. A process killed before atomic activation therefore
leaves enough evidence to remove a never-activated complete generation. Recovery
removes that target before its pending pointer, counting each against the cleanup
budget; if the budget is exhausted, the pointer remains for the next pass. The
active target is protected. Previously activated generations remain available to
running game snapshots; their lifecycle is separate from temporary-file cleanup.

## Installed content and game sessions

Transfers and queued jobs never modify the installed pointer. Full verification
and activation still use the existing serialized store and cross-process writer
lock. Cancellation, corruption and storage-full failures before commit preserve
the prior pointer, Cards and private images. Successful activation refreshes local
browsing through the existing SQLite projection. An active `GameSession` continues
to own its original immutable snapshot and generation paths; no session provider
is invalidated or content pool rebuilt during a download/update.

## Acceptance evidence

- Real anonymous HTTP tests cover streaming cancellation, pre-cancelled jobs with
  zero requests, cancellation before activation, fresh successful retry, tampering,
  timeout and no-space failures that preserve prior installed content.
- Store tests cover cancel-before-pointer rollback, activation winning a late
  cancellation, concurrent writers, bounded cleanup, live leases, safe pending
  targets and retained previous-generation image reads.
- Linux process tests hold real file locks and partial/unactivated files, verify a
  live process is protected, send SIGKILL, then reopen the store and recover with
  bounded passes while the old Pack remains readable.
- Controller tests cover one active transfer, queue capacity, duplicate requests,
  queued/active cancellation, scope disposal and an idle fresh scope. A real local
  update test verifies new browsing metadata while the original session snapshot
  and its private images remain intact across rounds.
- Widget tests cover reopening progress, cancellation, no-space errors and manual
  retry. Existing startup tests continue to prove no automatic catalog requests;
  the offline gameplay gate proves SQLite/private images and all rounds with zero
  HTTP clients.

Final command totals are recorded in `TODO.md`. This is host/process evidence;
physical Android process-death/airplane-mode release validation remains a separate
device gate. No backend deployment, publication, APK or OTA release is performed.
