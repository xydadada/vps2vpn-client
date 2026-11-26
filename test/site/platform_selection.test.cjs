const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const site = join(__dirname, '../../site');

// A DOM double for event/state tests. Layout and animations are deliberately
// inert; the production HTML, handlers and asynchronous startup run unchanged.
class Element {
  constructor() {
    this.children = [];
    this.dataset = {};
    this.attributes = new Map();
    this.listeners = new Map();
    this.style = { setProperty() {}, removeProperty() {} };
    this.classList = { add() {}, remove() {}, toggle() {}, replace() {}, contains: () => false };
    this.hidden = false;
    this.textContent = '';
    this.value = '';
    this.offsetWidth = this.clientWidth = 100;
    this.offsetHeight = 50;
    this.offsetLeft = this.offsetTop = 0;
  }

  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = nodes; }
  getBoundingClientRect() { return { left: 0, top: 1000, width: 100, height: 50 }; }
  closest(selector) { return selector === '[role="tab"]' ? this : null; }
  querySelectorAll(selector) {
    return selector === '[role="tab"]' ? this.children.filter((child) => child.dataset.value) : [];
  }
  querySelector(selector) {
    if (selector === '[aria-selected="true"]') {
      return this.children.find((child) => child.getAttribute('aria-selected') === 'true') ?? null;
    }
    return new Element();
  }
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function loadPage(search = '') {
  const html = readFileSync(join(site, 'index.html'), 'utf8');
  const elements = new Map([...html.matchAll(/\bid="([^"]+)"/g)].map((match) => [`#${match[1]}`, new Element()]));
  const select = (selector) => {
    if (!elements.has(selector)) elements.set(selector, new Element());
    return elements.get(selector);
  };
  for (const match of html.matchAll(/<button\b[^>]*\brole="tab"[^>]*>/g)) {
    const id = /\bid="([^"]+)"/.exec(match[0])[1];
    const value = /\bdata-value="([^"]+)"/.exec(match[0])[1];
    const button = select(`#${id}`);
    button.dataset.value = value;
    select(id.startsWith('tab-') ? '#platform-seg' : '#arch-seg').children.push(button);
  }
  select('#stars').hidden = true;
  const root = new Element();
  root.lang = 'en';
  const document = {
    documentElement: root,
    currentScript: { src: 'https://example.test/assets/app.js' },
    body: new Element(),
    querySelector: select,
    querySelectorAll: () => [],
    addEventListener() {},
    createElement(tag) {
      const node = new Element();
      if (tag === 'template') node.content = new Element();
      return node;
    },
  };
  const metadata = deferred();
  const timers = new Map();
  let timerId = 0;
  const context = vm.createContext({
    document,
    navigator: { userAgent: 'Windows NT 10.0', maxTouchPoints: 0 },
    location: { search, hash: '', pathname: '/', href: `https://example.test/${search}` },
    history: { replaceState() {} },
    matchMedia: () => ({ matches: true, addEventListener() {} }),
    CSS: { supports: () => false },
    getComputedStyle: () => ({ getPropertyValue: () => '', scrollPaddingTop: '0px' }),
    innerHeight: 800,
    scrollY: 0,
    addEventListener() {},
    setTimeout(callback) { timers.set(++timerId, callback); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    URL,
    URLSearchParams,
    fetch: () => metadata.promise.then(() => ({
      ok: true,
      text: async () => '# Changelog\n',
      json: async () => ({ tag: 'v1.2.3', publishedAt: '2026-01-01', assets: [] }),
    })),
  });
  context.window = context;
  for (const file of ['shared.js', 'app.js']) {
    vm.runInContext(readFileSync(join(site, 'assets', file), 'utf8'), context, { filename: file });
  }
  return {
    click(segment, id) {
      const target = select(`#${id}`);
      select(`#${segment}`).listeners.get('click')({ target });
    },
    selected(segment) {
      return select(`#${segment}`).querySelector('[aria-selected="true"]')?.dataset.value;
    },
    input(value) {
      const target = select('#cl-search');
      target.value = value;
      target.listeners.get('input')({ target });
      for (const [id, callback] of [...timers]) {
        timers.delete(id);
        callback();
      }
    },
    searchValue() { return select('#cl-search').value; },
    searchStatus() { return select('#cl-status').children.filter((child) => typeof child === 'string').join(''); },
    async releaseMetadata() {
      metadata.resolve();
      await new Promise(setImmediate);
      assert.match(select('#dl-meta').textContent, /1\.2\.3/);
    },
  };
}

test('device detection selects a default when the visitor has not chosen', async () => {
  const page = loadPage();
  await page.releaseMetadata();
  assert.equal(page.selected('platform-seg'), 'windows');
  assert.equal(page.selected('arch-seg'), 'x64');
});

test('late metadata keeps the platform and architecture selected while loading', async () => {
  const page = loadPage();
  page.click('platform-seg', 'tab-linux');
  page.click('arch-seg', 'arch-arm64');
  await page.releaseMetadata();
  assert.equal(page.selected('platform-seg'), 'linux');
  assert.equal(page.selected('arch-seg'), 'arm64');
});

test('a carried platform is applied when there is no newer selection', async () => {
  const page = loadPage('?platform=linux&arch=arm64');
  await page.releaseMetadata();
  assert.equal(page.selected('platform-seg'), 'linux');
  assert.equal(page.selected('arch-seg'), 'arm64');
});

test('an architecture selected for the detected platform is kept', async () => {
  const page = loadPage();
  page.click('platform-seg', 'tab-windows');
  page.click('arch-seg', 'arch-arm64');
  await page.releaseMetadata();
  assert.equal(page.selected('platform-seg'), 'windows');
  assert.equal(page.selected('arch-seg'), 'arm64');
});

test('a newer selection also wins over carried URL parameters', async () => {
  const page = loadPage('?platform=windows&arch=x64');
  page.click('platform-seg', 'tab-linux');
  page.click('arch-seg', 'arch-arm64');
  await page.releaseMetadata();
  assert.equal(page.selected('platform-seg'), 'linux');
  assert.equal(page.selected('arch-seg'), 'arm64');
});

test('an untouched carried search is still applied', async () => {
  const page = loadPage('?q=carried');
  await page.releaseMetadata();
  assert.equal(page.searchValue(), 'carried');
  assert.match(page.searchStatus(), /carried/);
});

test('a search entered during loading replaces the carried query', async () => {
  const page = loadPage('?q=carried');
  page.input('new search');
  await page.releaseMetadata();
  assert.equal(page.searchValue(), 'new search');
  assert.match(page.searchStatus(), /new search/);
});

test('clearing the search during loading does not restore the carried query', async () => {
  const page = loadPage('?q=carried');
  page.input('');
  await page.releaseMetadata();
  assert.equal(page.searchValue(), '');
  assert.equal(page.searchStatus(), '');
});
