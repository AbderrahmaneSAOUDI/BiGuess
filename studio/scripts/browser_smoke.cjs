// Optional release smoke test. Requires Playwright; no dependency enters the app.
const { chromium } = require('playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const expectedAuthDomain = process.env.STUDIO_EXPECTED_FIREBASE_AUTH_DOMAIN || (process.env.STUDIO_PUBLIC_CONFIG_FILE ? JSON.parse(fs.readFileSync(process.env.STUDIO_PUBLIC_CONFIG_FILE, 'utf8')).STUDIO_FIREBASE_AUTH_DOMAIN : null);
const authEnabled = process.env.STUDIO_AUTH_ENABLED === '1' || Boolean(process.env.STUDIO_PUBLIC_CONFIG_FILE);
const root = process.env.STUDIO_WEB_ROOT ? path.resolve(process.env.STUDIO_WEB_ROOT) : path.resolve(__dirname, '../build/web');
const headerFile = path.join(root, '_headers');
const headerRules = [];
if (fs.existsSync(headerFile)) {
  for (const line of fs.readFileSync(headerFile, 'utf8').split('\n')) {
    if (line.startsWith('/')) headerRules.push({pattern: line.trim(), headers: {}});
    else if (line.startsWith('  ') && headerRules.length) {
      const colon = line.indexOf(':');
      if (colon > 0) headerRules.at(-1).headers[line.slice(0, colon).trim()] = line.slice(colon + 1).trim();
    }
  }
}
const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.otf': 'font/otf', '.png': 'image/png', '.webp': 'image/webp', '.svg': 'image/svg+xml' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const file = path.resolve(root, '.' + decodeURIComponent(url.pathname));
  if (!file.startsWith(root + path.sep) && file !== root) {
    res.writeHead(403).end(); return;
  }
  const target = fs.existsSync(file) && fs.statSync(file).isFile()
    ? file : path.join(root, 'index.html');
  for (const rule of headerRules) {
    if (rule.pattern.endsWith('*') ? url.pathname.startsWith(rule.pattern.slice(0, -1)) : url.pathname === rule.pattern) {
      for (const [name, value] of Object.entries(rule.headers)) res.setHeader(name, value);
    }
  }
  res.setHeader('Content-Type', types[path.extname(target)] || 'application/octet-stream');
  fs.createReadStream(target).pipe(res);
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = process.env.STUDIO_ORIGIN || `http://127.0.0.1:${server.address().port}`;
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
      let offline = false;
      const external = [];
      const privateCalls = [];
      const authHelpers = [];
      context.on('request', request => {
        const requestUrl = new URL(request.url());
        if (requestUrl.pathname.startsWith('/content/v1/')) privateCalls.push(request.url());
        if (requestUrl.pathname.startsWith('/__/auth/')) authHelpers.push(requestUrl.hostname);
      });
      await context.route('**/*', route => {
        if (authEnabled) return route.continue();
        if (!route.request().url().startsWith(origin + '/')) {
          external.push(route.request().url());
          return route.abort();
        }
        return route.continue();
      });
      const page = await context.newPage();
      page.on('pageerror', error => errors.push(String(error)));
      page.on('requestfailed', request => {
        // Chrome retries/aborts bookmark images during URL changes; verify the favicon separately.
        if (!request.url().endsWith('/favicon.webp')) errors.push('Failed request: ' + request.url());
      });
      page.on('console', message => {
        if (message.type() === 'error' && !(offline && message.text().includes('ERR_INTERNET_DISCONNECTED'))) errors.push(message.text());
      });
      const response = await page.goto(origin + '/dashboard');
      if (headerRules.length || process.env.STUDIO_ORIGIN) {
        assert.equal(response.headers()['x-content-type-options'], 'nosniff');
        assert(response.headers()['content-security-policy'].includes("connect-src 'self'"));
      }
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      if (authEnabled) {
        await page.getByRole('button', {name: 'Continue with Google', exact: true}).waitFor().catch(async error => {
          console.error('Auth startup diagnostics:', errors, await page.locator('body').innerText());
          await page.screenshot({path: '/tmp/t27-auth-startup-failure.png'});
          throw error;
        });
        assert.equal(await page.getByRole('button', {name: 'Topics', exact: true}).count(), 0);
        for (const routePath of ['/topics', '/cards', '/my-packs', '/profile', '/login']) {
          await page.goto(origin + routePath);
          await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
          await page.getByRole('button', {name: 'Continue with Google', exact: true}).waitFor();
          assert.equal(await page.getByRole('button', {name: 'Topics', exact: true}).count(), 0);
        }
        const popupPromise = page.waitForEvent('popup');
        await page.getByRole('button', {name: 'Continue with Google', exact: true}).click();
        const popup = await popupPromise;
        await popup.waitForURL(url => url.hostname === 'accounts.google.com', {timeout: 30000});
        if (expectedAuthDomain) {
          assert(authHelpers.includes(expectedAuthDomain), 'The intended Firebase auth helper must be used');
          assert(authHelpers.every(domain => domain === expectedAuthDomain), 'No previous Firebase project helper may be used');
        }
        console.log('Google popup reached accounts.google.com from ' + origin);
        await popup.close();
        await page.getByText('Sign-in was cancelled. Try again when ready.').waitFor({timeout: 30000});
        assert.equal(await page.getByRole('button', {name: 'Topics', exact: true}).count(), 0);
        assert.deepEqual(privateCalls, [], 'No private API calls before Worker authorization');
        await page.screenshot({path: `/tmp/t27-auth-${mobile ? 'mobile' : 'desktop'}.png`});
        assert.deepEqual(errors.filter(error => !error.includes('popup-closed-by-user')), [], 'No browser runtime errors');
        assert.equal(await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length), 0);
        await context.close();
        console.log(`${mobile ? 'Mobile' : 'Desktop'}: real Firebase popup, cancellation and protected deep links passed`);
        continue;
      }
      await page.getByRole('heading', { name: /^Studio under construction/ }).waitFor();
      await page.screenshot({ path: `/tmp/studio-design-dashboard-${mobile ? 'mobile' : 'desktop'}.png` });
      if (process.env.STUDIO_EXPECTED_DASHBOARD_COPY) {
        const statusText = await page.getByRole('heading', { name: /^Studio under construction/ }).textContent();
        assert(statusText.includes(process.env.STUDIO_EXPECTED_DASHBOARD_COPY), 'The expected Studio copy must be visible');
      }
      const faviconUrl = new URL(await page.locator('link[rel=icon]').getAttribute('href'), origin).href;
      assert(faviconUrl.startsWith(origin + '/'));
      const faviconResponse = await context.request.get(faviconUrl);
      assert.equal(faviconResponse.status(), 200);
      assert(faviconResponse.headers()['content-type'].includes('image/webp'));
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
      await page.waitForLoadState('networkidle');
      offline = true;
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
