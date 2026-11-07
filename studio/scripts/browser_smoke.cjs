// Optional release smoke test. Requires Playwright; no dependency enters the app.
const { chromium } = require('playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../build/web');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.otf': 'font/otf', '.png': 'image/png', '.webp': 'image/webp' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const file = path.resolve(root, '.' + decodeURIComponent(url.pathname));
  if (!file.startsWith(root + path.sep) && file !== root) {
    res.writeHead(403).end(); return;
  }
  const target = fs.existsSync(file) && fs.statSync(file).isFile()
    ? file : path.join(root, 'index.html');
  res.setHeader('Content-Type', types[path.extname(target)] || 'application/octet-stream');
  fs.createReadStream(target).pipe(res);
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({
    ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}),
    args: ['--no-sandbox'],
  });
  try {
    for (const mobile of [false, true]) {
      const context = await browser.newContext({
        viewport: mobile ? { width: 360, height: 740 } : { width: 1440, height: 900 },
        isMobile: mobile, hasTouch: mobile,
      });
      const errors = [];
      const external = [];
      await context.route('**/*', route => {
        if (!route.request().url().startsWith(origin + '/')) {
          external.push(route.request().url());
          return route.abort();
        }
        return route.continue();
      });
      const page = await context.newPage();
      page.on('pageerror', error => errors.push(String(error)));
      await page.goto(origin + '/dashboard');
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      await page.getByRole('heading', { name: /^Studio under construction/ }).waitFor();
      await page.screenshot({ path: `/tmp/studio-design-dashboard-${mobile ? 'mobile' : 'desktop'}.png` });
      const navigate = async (label, expected) => {
        if (mobile) await page.getByRole('button', { name: 'Open navigation menu' }).tap();
        const control = page.getByRole('button', { name: new RegExp('^' + label + '(?:\\s|$)') });
        if (mobile) await control.tap(); else await control.click();
        await page.waitForURL(origin + expected);
        await page.getByRole('heading', { name: label, exact: true }).waitFor();
      };
      await navigate('Topics', '/topics');
      await navigate('My Packs', '/my-packs');
      await page.goBack();
      await page.waitForURL(origin + '/topics');
      await page.getByRole('heading', { name: 'Topics', exact: true }).waitFor();
      await page.goForward();
      await page.waitForURL(origin + '/my-packs');
      await page.reload();
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      await page.getByRole('heading', { name: 'My Packs', exact: true }).waitFor();
      await navigate('Cards', '/cards');
      await navigate('Profile', '/profile');
      await page.getByRole('button', { name: 'Sign in', exact: true }).click();
      await page.getByRole('heading', { name: /^Sign-in is not available yet/ }).waitFor();
      await context.setOffline(true);
      await navigate('Dashboard', '/dashboard');
      await navigate('Cards', '/cards');
      if (!mobile) {
        // Keyboard-only traversal reaches a destination and activates it.
        for (let i = 0; i < 12 && !page.url().endsWith('/topics'); i++) {
          await page.keyboard.press('Tab');
          await page.keyboard.press('Enter');
          await page.waitForTimeout(80);
        }
        assert(page.url().endsWith('/topics'), 'Topics must be reachable by keyboard');
      }
      await page.screenshot({ path: `/tmp/t26-studio-${mobile ? 'mobile' : 'desktop'}.png` });
      assert.deepEqual(external, [], 'No external requests, including CDN resources');
      assert.deepEqual(errors, [], 'No browser runtime errors');
      assert.equal(await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length), 0);
      assert.equal(await page.evaluate(() => localStorage.length), 0);
      assert.deepEqual(await page.evaluate(async () => await indexedDB.databases()), []);
      await context.close();
      console.log(`${mobile ? 'Mobile touch' : 'Desktop pointer/keyboard'}: routes, history, refresh, offline and public boundary passed`);
    }
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
