// FW-103: kontor's web UI in headless Chromium.  Started by tests/ui_smoke.sh
// with the base URL and a session ("<id>:<secret>") as arguments.
//
// Checks: /ui/ loads with no console error and no CSP violation; a session
// handed over in the fragment (FW-21, the SSO path) signs in; the UI then
// asks kontor for the catalog and the published project is in it.  The page
// is a canvas, so what it shows is checked on the wire, plus a screenshot.
const { chromium } = require('playwright');

const [base, session, shot] = process.argv.slice(2);
let fails = 0;
const ok = (what, cond, more) => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${what}${cond || !more ? '' : ': ' + more}`);
  if (!cond) fails++;
};

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  const calls = [];
  page.on('response', async (r) => {
    const u = new URL(r.url());
    if (u.pathname.startsWith('/api/')) {
      let body = '';
      try { body = await r.text(); } catch (e) { /* body gone */ }
      calls.push({ path: u.pathname, status: r.status(), body });
    }
  });
  const waitCall = async (path, ms) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const hit = calls.find((c) => c.path === path);
      if (hit) return hit;
      await page.waitForTimeout(100);
    }
    return null;
  };

  console.log('anonymous visit');
  const first = await page.goto(`${base}/ui/`);
  ok('/ui/ answers 200', first.status() === 200, first.status());
  const who = await waitCall('/api/v1/whoami', 15000);
  ok('the UI started and asked who it is', who !== null);
  ok('anonymous whoami is 200', who && who.status === 200, who && who.status);

  console.log('session from the fragment (FW-21)');
  calls.length = 0;
  await page.goto(`${base}/ui/#token=${session}`);
  const cat = await waitCall('/api/v1/catalog', 15000);
  ok('catalog requested', cat !== null);
  ok('catalog 200', cat && cat.status === 200, cat && cat.status);
  ok('catalog lists lib-a', cat && cat.body.includes('"lib-a"'), cat && cat.body.slice(0, 200));
  const me = calls.find((c) => c.path === '/api/v1/whoami');
  ok('signed in as ops', me && me.body.includes('"ops"'), me && me.body);
  ok('fragment removed from the address', !page.url().includes('token='), page.url());
  const kept = await page.evaluate(() => sessionStorage.getItem('kontor.session'));
  ok('session kept for the tab', kept === session, kept);
  await page.waitForTimeout(500);
  if (shot) await page.screenshot({ path: shot });

  ok('no console errors or CSP violations', errors.length === 0, errors.join(' | '));
  await browser.close();
  console.log(fails ? `FAIL ui_smoke: ${fails} failed` : 'PASS ui_smoke');
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
