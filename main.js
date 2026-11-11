// Jit landing page. Three small jobs:
//  1. draw the commit graph in the left gutter and extend it as the page scrolls,
//  2. the dark/light comparison divider in the hero,
//  3. point the download buttons at the newest release (release.json is written by scripts/site/publish.sh).

const RELEASES_URL = 'https://github.com/ashkanRmk/jit/releases';
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const SVG = 'http://www.w3.org/2000/svg';

/* ---------- 1. The graph ---------- */

const history = document.querySelector('.history');
const svg = history.querySelector('.lanes');
const commits = [...history.querySelectorAll('.commit')];
let nodes = [];        // { y, el, section }
let clipRect = null;
let drawn = 0;         // how far down the lanes are drawn, in px
let target = 0;
let ticking = false;

const el = (name, attrs, parent) => {
  const node = document.createElementNS(SVG, name);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  parent?.append(node);
  return node;
};

function buildGraph() {
  const style = getComputedStyle(document.documentElement);
  const x0 = parseFloat(style.getPropertyValue('--lane-x'));
  const gap = parseFloat(style.getPropertyValue('--lane-gap'));
  const gutter = parseFloat(style.getPropertyValue('--gutter'));
  const laneX = (i) => x0 + i * gap;
  const top = history.getBoundingClientRect().top;
  const height = history.offsetHeight;
  const r = Math.min(16, gap);

  svg.replaceChildren();
  svg.setAttribute('viewBox', `0 0 ${gutter} ${height}`);
  svg.setAttribute('width', gutter);
  svg.setAttribute('height', height);

  const defs = el('defs', {}, svg);
  const clip = el('clipPath', { id: 'drawn' }, defs);
  clipRect = el('rect', { x: -10, y: 0, width: gutter + 20, height: 0 }, clip);
  const lanes = el('g', { 'clip-path': 'url(#drawn)' }, svg);
  const marks = el('g', {}, svg);

  const points = commits.map((section) => {
    const anchor = section.querySelector('[data-node]');
    const box = anchor.getBoundingClientRect();
    const lineHeight = parseFloat(getComputedStyle(anchor).lineHeight) || box.height;
    return {
      section,
      lane: Number(section.dataset.lane),
      kind: section.dataset.kind || 'commit',
      y: Math.round(box.top - top + Math.min(box.height, lineHeight) / 2),
    };
  });

  // main: from the first commit to the last.
  const first = points[0];
  const last = points[points.length - 1];
  el('path', { class: 'l0', d: `M${laneX(0)} ${first.y}V${last.y}` }, lanes);

  // The feature branch leaves main at the commit before it and merges into the last commit.
  const branch = points.filter((p) => p.lane === 1);
  if (branch.length) {
    const from = points[points.indexOf(branch[0]) - 1];
    const x = laneX(1);
    el('path', {
      class: 'l1',
      d: `M${laneX(0)} ${from.y}H${x - r}Q${x} ${from.y} ${x} ${from.y + r}V${last.y - r}Q${x} ${last.y} ${x - r} ${last.y}H${laneX(0)}`,
    }, lanes);
  }

  // A fork that is never merged: it leaves at the open-source commit and runs off the page.
  const fork = points.find((p) => p.section.hasAttribute('data-fork'));
  if (fork) {
    const x = laneX(2);
    el('path', {
      class: 'l2',
      d: `M${laneX(0)} ${fork.y}H${x - r}Q${x} ${fork.y} ${x} ${fork.y + r}V${height + 40}`,
    }, lanes);
  }

  nodes = points.map((p) => {
    const x = laneX(p.lane);
    // A faint rule from the node to its heading, as in the app's graph rows.
    el('path', { class: `link l${p.lane}`, d: `M${x + 12} ${p.y}H${gutter + 12}` }, lanes);
    const g = el('g', { class: 'node' }, marks);
    if (p.kind === 'head') {
      el('circle', { class: `dot f${p.lane}`, cx: x, cy: p.y, r: 8 }, g);
    } else if (p.kind === 'merge') {
      el('circle', { class: `l${p.lane}`, cx: x, cy: p.y, r: 11 }, g);
      el('circle', { class: `dot f${p.lane}`, cx: x, cy: p.y, r: 4.5 }, g);
    } else {
      el('circle', { class: `l${p.lane}`, cx: x, cy: p.y, r: 8 }, g);
    }
    return { y: p.y, el: g, section: p.section };
  });

  applyDraw();
}

function applyDraw() {
  clipRect.setAttribute('height', Math.max(0, drawn));
  for (const n of nodes) {
    if (n.y <= drawn + 1) {
      n.el.classList.add('is-reached');
      n.section.classList.add('is-reached');
    }
  }
}

function step() {
  const delta = target - drawn;
  if (delta < 0.5) {
    drawn = target;
    applyDraw();
    ticking = false;
    return;
  }
  drawn += delta * 0.14;
  applyDraw();
  requestAnimationFrame(step);
}

function onScroll() {
  const top = history.getBoundingClientRect().top;
  const reach = innerHeight * 0.8 - top;
  const atEnd = innerHeight + scrollY >= document.documentElement.scrollHeight - 4;
  target = Math.max(target, atEnd ? history.offsetHeight + 60 : reach);
  if (reduceMotion) {
    drawn = target;
    applyDraw();
  } else if (!ticking) {
    ticking = true;
    requestAnimationFrame(step);
  }
}

function initGraph() {
  buildGraph();
  if (reduceMotion) {
    target = drawn = history.offsetHeight + 60;
    applyDraw();
  } else {
    // The first commit is there from the first frame; the lane grows from it.
    drawn = nodes[0].y;
    applyDraw();
    onScroll();
    addEventListener('scroll', onScroll, { passive: true });
  }
  // Images and fonts move the commits; redraw when the layout settles or changes.
  new ResizeObserver(() => { buildGraph(); onScroll(); }).observe(history);
}

/* ---------- 2. Dark / light comparison ---------- */

function initCompare() {
  const figure = document.querySelector('.compare');
  const range = figure.querySelector('.compare-range');
  const set = (value) => figure.style.setProperty('--split', `${value}%`);
  const rest = Number(range.value);
  range.addEventListener('input', () => set(range.value));

  if (reduceMotion) { set(rest); return; }

  // One sweep on load: the window starts dark and the light half slides in from the right.
  const start = performance.now() + 500;
  const duration = 1300;
  const ease = (t) => 1 - Math.pow(1 - t, 4);
  let cancelled = false;
  range.addEventListener('pointerdown', () => { cancelled = true; }, { once: true });
  range.addEventListener('keydown', () => { cancelled = true; }, { once: true });
  const frame = (now) => {
    if (cancelled) return;
    const t = Math.min(1, Math.max(0, (now - start) / duration));
    set(100 - (100 - rest) * ease(t));
    if (t < 1) requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

/* ---------- 3. Download links ---------- */

async function initDownload() {
  let release;
  try {
    const response = await fetch('release.json', { cache: 'no-cache' });
    if (!response.ok) return;
    release = await response.json();
  } catch {
    return; // Links keep pointing at the releases page.
  }
  if (!release?.url?.startsWith('https://github.com/ashkanRmk/jit/releases/download/')) return;

  for (const link of document.querySelectorAll('[data-download]')) link.href = release.url;
  for (const label of document.querySelectorAll('[data-download-label]')) {
    label.textContent = `Download Jit ${release.version}`;
  }
  const meta = document.querySelector('[data-release-meta]');
  if (meta && release.size) {
    meta.textContent = `${(release.size / 1e6).toFixed(1)} MB. macOS 26 or later, Apple silicon`;
  }
  const tag = document.querySelector('[data-version-tag]');
  if (tag) {
    tag.textContent = release.tag;
    tag.hidden = false;
  }
}

function initCopy() {
  for (const button of document.querySelectorAll('[data-copy]')) {
    button.addEventListener('click', async () => {
      const text = document.getElementById(button.dataset.copy).textContent;
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = 'Copied';
      } catch {
        button.textContent = 'Press ⌘C';
        getSelection().selectAllChildren(document.getElementById(button.dataset.copy));
      }
      setTimeout(() => { button.textContent = 'Copy'; }, 1800);
    });
  }
}

// Replay the logotype when it is pointed at or clicked.
for (const logo of document.querySelectorAll('.logotype')) {
  const replay = () => {
    if (reduceMotion) return;
    logo.classList.remove('play');
    void logo.getBoundingClientRect();
    logo.classList.add('play');
  };
  logo.addEventListener('pointerenter', replay);
  logo.addEventListener('click', replay);
}

initCompare();
initCopy();
initGraph();
initDownload();
