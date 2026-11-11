# T43 verification — optional Home checks and verified incremental updates

Home offers **Manage installed Packs** when private downloaded Packs exist. Its
**Check for updates** button is the ordinary content-update discovery trigger.
Opening Home, opening management, rebuilding, returning from a game and restarting
perform no update request. A check only records availability; **Update** is a
separate user action. The installed revision remains unchanged until that action
successfully commits. Installed-Pack Update actions were removed from the Topic's
Pack browser; its Download action remains for Packs not installed yet.

The management screen distinguishes **Not checked**, **Update available**,
**Up to date**, **Unavailable online**, progress, cancellation and errors. Last-check
and last-update timestamps describe explicit work. Failed checks retain the last
complete status result and existing content. No public account, Firebase identity,
billing or Studio credentials enter this flow.

## Small discovery and compact deltas

The anonymous `POST /content/v1/sync/revisions` request lists only explicit locally
installed Pack IDs/revisions in batches of at most 100. Unchanged responses must
match both the verified installed revision and manifest hash. They transfer no
Cards, images, target manifests or archives. Unknown/unavailable/deleted status does
not remove installed content or apply a tombstone; that policy remains T44.
Local-only development generations are excluded before any revision request, and
cannot be used as incremental bases. Private-only and mixed-store tests verify
that their Pack/Topic IDs never enter the public request body.

For a selected Update, Mobile requests the existing delta endpoint with
`fromRevision`, `toRevision` and the new **opt-in** `includeManifestPatch=1` query.
Default v1 delta responses remain unchanged for existing consumers. The optional
patch adds target Topic/Pack metadata, provenance mode/Pack rights, only new/changed
Card rights, and compact Card-ID/object-key order lists. Alongside changed Card
records, removed IDs and new object descriptors, this reconstructs the exact
canonical target manifest without retrieving unchanged Card records or a full
manifest. Variant ETags cover their respective response bytes; Mobile validates the
delta ETag against its received body when present.

The backend 100→105 fixture returns five Card upserts, five changed rights records
and five new image objects. The Mobile fixture performs one revision POST, one
delta GET, one target signature GET and five new image GETs: it never requests the
full target manifest or archive. Existing 100 private image objects are read
locally. Order lists contain IDs/keys, rather than repeated unchanged Card records.

## Trust, private activation and failure behavior

Full downloads and incremental updates share the pinned Ed25519 publication-receipt
verifier. Incremental installation checks the receipt domain, schema, key/SPKI
fingerprint, signature, identities, target revision and manifest hash. Reconstructed
canonical manifest bytes must match the signed hash **and signed byte length**;
relationships and cleared provenance are validated before activation. Every reused
or downloaded image is verified against that target manifest, with bounded metadata,
image and aggregate sizes, fixed same-origin paths, no redirects and timeouts.

The locally assembled ZIP is an installation representation. Its serialization need
not equal the publisher's complete archive bytes: the signed canonical manifest and
all its exact image hashes/sizes authenticate the incremental result. No claim is
made that the publisher's archive hash matches a locally regenerated ZIP.

The resulting complete Pack is staged in leased application-private storage and
installed through the existing serialized atomic-generation store. Stale base
revisions, conflicting same-revision content and downgrades fail without overwriting
newer local work. Old generation image paths remain valid for immutable snapshots.
Successful activation refreshes the disposable SQLite view. If that projection
fails, the UI explicitly requests restart to reopen the verified saved files.

One shared transfer lease serializes initial downloads and update checks/installs,
including local projection. Waiting initial-download jobs retain their bounded
queue; update operations report busy while another transfer runs. Cancel aborts
network work and checks again before activation; once atomic activation starts,
completion wins. Pending requests do not automatically retry. Missing delta history
reports an error and retains the installed revision; no silent full-download fallback
or unrequested publication is introduced.

Start closes the update repository and drains active checks/updates alongside
initial downloads and app-update work. The gameplay gate rejects new update calls
through completion/Pro replay until Home. Closing the management page does not
withdraw an already explicit Update; process death safely restarts from the last
committed generation. On restart, T41's bounded lease/pending-generation cleanup
reclaims abandoned private staging without initiating requests or deleting previous
activated generations. A fresh Check/Update is required.

## Acceptance evidence

- Real-loopback Mobile tests: exact 100→105 request/byte scope; small unchanged POST;
  changed/removed metadata and image reuse; rights/order/body/signature/image tamper;
  untrusted pins; outage/history errors; cancellation/manual retry; storage-full and
  preactivation rollback; stale local base preservation.
- Controller/UI tests: no requests on Home/management/rebuild; explicit Check versus
  Update; old revision retained after Check; timestamps/statuses; shared transfer
  exclusion; cancel/drain at Start; gameplay blocks calls and Home remains inert.
  A lease handoff regression test verifies a later job retains its cancellation.
- Backend/contract tests: opt-in compatibility, exact reconstruction/signature hash,
  only five new objects/records, rights-only changes, variant ETags/304, strict query
  validation and published-only visibility. No private Studio fields are added.
- Existing process-death, concurrent install, private-image and offline all-rounds
  tests run in the full Mobile suite. They cover the same leased staging, writer
  lock, atomic pointer and immutable-generation mechanisms used by delta installs.

Final totals are recorded in `TODO.md`. Endpoint and public pins remain the existing
build configuration. The optional backend protocol addition is implemented and
verified locally; deploying it remains separately authorized. Physical Android and
published Shorebird-engine validation remain device/release gates. No deployment,
production Pack publication, APK or OTA release was performed.
