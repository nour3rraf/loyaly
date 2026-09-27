import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

const SRC = resolve('loyaly-final.html');
const OUT = resolve('export');
mkdirSync(OUT, { recursive: true });

const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
const browser = await chromium.launch({ proxy: proxy ? { server: proxy } : undefined });
const ctx = await browser.newContext({ viewport: { width: 3200, height: 3200 }, deviceScaleFactor: 1, ignoreHTTPSErrors: true });
const page = await ctx.newPage();
await page.goto('file://' + SRC, { waitUntil: 'load' });

await page.addStyleTag({ content: `
  body { padding: 0 !important; }
  .screen { overflow: hidden !important; border-radius: 0 !important; box-shadow: none !important; }
  .notif { animation: none !important; }
  header.top, footer.foot, .pair-label { display: none !important; }
` });
await page.evaluate(() => document.body.classList.add('zoom-full'));
await page.evaluate(() => document.fonts.ready);
await page.evaluate(async () => {
  const imgs = [...document.images];
  await Promise.all(imgs.map(i => i.complete ? null : new Promise(r => { i.onload = i.onerror = r; })));
});
await page.waitForTimeout(800);

const fontOk = await page.evaluate(() => document.fonts.check('700 40px Poppins'));
console.log('Poppins loaded:', fontOk);

const screens = await page.$$('.screen');
console.log('screens found:', screens.length);
for (let i = 0; i < screens.length; i++) {
  const lang = i < 6 ? 'es' : 'en';
  const n = (i % 6) + 1;
  const name = `${lang}-0${n}.png`;
  await screens[i].screenshot({ path: `${OUT}/${name}`, type: 'png', omitBackground: false });
  const box = await screens[i].boundingBox();
  console.log(name, Math.round(box.width) + 'x' + Math.round(box.height));
}
await browser.close();
