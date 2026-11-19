# BiGuess — Clean-slate coding agent rules

The human owner controls scope, architecture, commits and deployments. Start with `TODO/TODO.md` and exactly one owner-selected task in the Game, Content or Studio roadmap.

**Never read, import, copy, run, use as a template, or depend on code/configuration/assets in `OLD/` unless the owner explicitly authorizes it for that exact task.** We are creating every new module from scratch, including backend infrastructure. Do not treat previous TODOs, old agents, old scripts or old deployment workflows as binding.

**Studio is a standalone web dashboard. Flutter must never be used in Studio.** Only Game may use Flutter. Game, Content and Studio may connect only through approved public/authorized contracts.

Before coding: explain the requirement, dependencies, alternatives, design choice, affected files, risks and test plan in simple language. Get owner approval for decisions and gates.

During coding: implement only the selected task; use small understandable modules, add focused tests, and use synthetic or rights-cleared content. No speculative features, hidden framework changes, secret material, or unrelated refactors.

After coding: show the diff, file responsibilities, data flow, tests actually run, remaining risks and reproduce steps. **Never automatically commit, push, merge, deploy, publish, migrate production data, remove cloud resources or edit credentials.** Wait for explicit owner approval. Do not check off a task until owner acceptance.
