// Verification-only extension of the tracked synthetic-identity sync harness.
// Run from any directory with Playwright on NODE_PATH, after building
// studio/test/browser_dataset_app.dart into studio/build/dataset-web.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const root = path.resolve(__dirname, '../../../..');
const harness = path.join(root, 'studio/scripts/sync_browser.cjs');
process.chdir(path.join(root, 'studio'));
const original = fs.readFileSync(harness, 'utf8');
const anchor = "    for (const uid of ['a','b','owner']) {";
if (original.split(anchor).length !== 2) throw new Error('Sync harness structure changed; review extension');
const extension = `
    // Account restoration is synthetic; IndexedDB/UI/service-worker are real.
    const closedTab = await open('a');
    await closedTab.evaluate(async () => { await navigator.serviceWorker.ready; });
    const writesBeforeClosure = requests.filter(r => r.method === 'POST').length;
    await context.setOffline(true);
    await text(closedTab,/Offline workspace — local edits only/).waitFor();
    await edit(closedTab,'offline tab-close draft');
    await queue(closedTab);
    await closedTab.close();
    // Offline navigation has no identity-bearing query: such URLs are
    // deliberately excluded from static shell caching. Model SDK restoration.
    await context.addInitScript(() => sessionStorage.setItem('biguess-browser-fixture-identity','a'));
    const reopenedTab = await context.newPage(); diagnostic = reopenedTab;
    reopenedTab.on('pageerror',error => errors.push(String(error)));
    await reopenedTab.goto(origin + '/my-packs');
    await reopenedTab.locator('flt-glass-pane').waitFor({state:'attached'});
    const semantics = reopenedTab.locator('flt-semantics-placeholder');
    if (await semantics.count()) await semantics.evaluate(el => el.click());
    // Closing a tab destroys its offline-readiness marker. A new tab must
    // authorize online, even with restored identity and durable IndexedDB.
    await text(reopenedTab,/No completed authorized dataset is available/).waitFor();
    assert.equal(await text(reopenedTab,'offline tab-close draft').count(),0);
    await context.setOffline(false);
    await text(reopenedTab,'offline tab-close draft').waitFor();
    await text(reopenedTab,'Unsent commit — queued locally').waitFor();
    assert.equal(requests.filter(r => r.method === 'POST').length,writesBeforeClosure);
    assert.deepEqual(errors,[]);
    await context.close();
    console.log('T46 actual tab close PASS: new offline tab denied until fresh online authorization; persisted draft and unsent queue recovered without writes.');
    return;
`;
const execution = new Module(harness, module);
execution.filename = harness;
execution.paths = Module._nodeModulePaths(path.dirname(harness));
execution._compile(original.replace(anchor, extension + anchor), harness);
