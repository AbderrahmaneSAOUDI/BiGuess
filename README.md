# BiGuess — Clean-Slate Rebuild

BiGuess is being rebuilt **from zero**. All former tracked files (including all old Game, Content backend, Studio, tooling and TODOs) are under `OLD/`.

## Active structure

- `game/` — fresh Flutter/Dart mobile application only.
- `content/` — fresh Content service, database and Pack distribution API.
- `studio/` — fresh **web dashboard**. Flutter is strictly prohibited here.
- `TODO/TODO.md` — master execution and cross-project dependency map.
- `TODO/GAME.md`, `TODO/CONTENT.md`, `TODO/STUDIO.md` — separate ordered task plans.
- `AGENTS.md` — new owner-review-first AI coding rules.
- `OLD/` — the complete tracked former repository as a reference only.

No active application code exists at the new root yet. Every module is intentionally a blank workspace until its own tasks are started. Do not import or execute files from OLD.

## Product boundaries

The Game remains an offline-first, face-to-face identity guessing app, working locally after Packs are downloaded. Studio is a browser dashboard for authorized content contributors. Content provides metadata, images and verified Pack distribution. Contracts must be approved before integration.

The former blueprint is historical until the owner approves specific decisions again. This repository reset does **not** automatically retire production resources, delete Cloudflare/Firebase data, deploy a site, or release an Android app.

Read [the new TODO home](TODO/TODO.md) first.
