# BiGuess — Master TODO

**Clean-slate restart:** everything previously tracked is preserved inside [OLD/](../OLD/); no legacy source or infrastructure is reused. The three new independent workspaces are [Game](../game/), [Content](../content/), and [Studio](../studio/).

## Non-negotiable decisions

- **Game** is Flutter/Dart mobile only, offline-first after installing verified Packs.
- **Content** is a *new* backend/API/storage system, not an adaptation of the old service.
- **Studio** is a **web dashboard**, never Flutter Web. React/TypeScript/Vite is a proposed initial stack; owner approval of the final frontend decision is required.
- Game, Content and Studio meet only through reviewed typed contracts. They can be designed and built in parallel with explicit dependency gates.
- Every AI task requires a pre-implementation explanation, owner-approved choices, tests, a changed-file walk-through, and owner acceptance. No automatic commits or deployment.

## Three roadmaps

| Roadmap | Scope | Minimum task count |
|---|---|---:|
| [GAME.md](GAME.md) | Flutter Game, local rounds, installed Packs, offline play | 55 |
| [CONTENT.md](CONTENT.md) | Schema, security, publishing, catalog and Pack distribution | 56 |
| [STUDIO.md](STUDIO.md) | Browser dashboard, authorization, authoring and publishing | 56 |

No tasks are completed in the new project. All reported test results and prior achievements belong to OLD only.

## Shared gates and dependencies

- [ ] **H01 — Product decision:** Owner confirms the exact first-playable Game rules, Topic → Pack → Card definition, roles, legally cleared test-content policy, and explicitly excluded features. Blocks G01/C01/S01.
- [ ] **H02 — Independent bootstrap:** G04, C11 and S10 create blank new Game, Content and Studio projects. No imports from OLD.
- [ ] **H03 — Shared contract:** C04–C10, G07 and S14 agree on IDs, Card/difficulty/image semantics, errors, public catalog and signed/verified Pack format. Freeze v1 *before* integration.
- [ ] **H04 — Web Studio design:** S02–S09 approve web framework, screens and responsive UX. Flutter is forbidden.
- [ ] **H05 — Local Game proof:** G12–G27 complete playable rounds with synthetic fixture Cards; no network or user accounts required.
- [ ] **H06 — Local Content proof:** C11–C22 create a testable new service and migrations with synthetic fixtures.
- [ ] **H07 — Private content/access gate:** C23–C36 plus S20–S25 establish server-verified roles and rights clearance before publication.
- [ ] **H08 — Studio authoring proof:** S15–S19 and S26–S40 create, edit and validate private content; fixture-first until the authenticated API is ready.
- [ ] **H09 — Commercial policy gate:** G48 resolves local Free/Pro rules before G49; no billing work is implied.
- [ ] **H10 — Published fixture:** C37–C42 and S41–S42 prove one complete, rights-cleared/synthetic Pack can be published in a safe test environment.
- [ ] **H11 — Game integration:** G38–G42 plus C39–C42 prove download once, install safely and play offline.
- [ ] **H12 — Synchronization gate:** C43–C46, G44–G46 and S42–S43 validate manual updates, safe revision changes and deliberate deletion semantics.
- [ ] **H13 — End-to-end test:** C51–C52, G50–G52 and S47–S50 verify Studio → Content → Game plus unauthorized-access cases.
- [ ] **H14 — Staging gate:** C53 and S51–S52, with Game release review, approve staged environments, cost limits, secrets and rollback.
- [ ] **H15 — Human trial:** G52 and S53 show actual user observations, not just code tests.
- [ ] **H16 — Production gate:** G55, C55–C56 and S54–S56 each require explicit approval. Backend deploy, Studio hosting and Android release are separate operations.

## Recommended first steps (can run concurrently after gates)

1. Approve H01, C02, and S03 (including technology and MVP size).
2. Build G01–G04 (new Flutter foundation).
3. Build C01–C11 (new backend domain and foundation).
4. Build S01–S10 (web dashboard design and foundation).
5. Freeze H03 contracts before any module-to-module integration.
6. Prove local game first at H05, while Content and Studio develop independently.

## Completion contract

For **every** task, the AI must explain: problem; design and rejected alternatives; exact files touched; how the data flows; tests actually run; failure/rollback considerations; and a reproducible demonstration. Owner review is required before checking a task complete. A green test report alone is insufficient.

No old assets become publishable merely because they are in OLD; use synthetic or independently rights-cleared content. No production cloud deletion, backend migration, DNS change, signing or deployment is authorized by this TODO or by moving tracked files. Cloud services and existing deployed websites are outside Git and require independent retirement plans.
