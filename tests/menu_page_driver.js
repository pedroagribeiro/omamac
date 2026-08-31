// menu_page_driver.js — drives menu/menu.html's <script> block in Node with a
// minimal DOM shim, so tests observe what the page actually POSTS rather than
// just what substrings appear in its source. Usage:
//   OMAMAC_JSON='{...}' node menu_page_driver.js <path-to-menu.html> <scenario>
// Scenarios: enter-enter (root -> first submenu -> select first item),
//            escape (root -> close),
//            bg-render-thrice (root -> Background, then two more renders
//            with no thumbnails ever supplied by the host — reproduces the
//            re-render-while-pending path that must only request a preview
//            once per name).
// Prints the captured window.webkit.messageHandlers.omamac.postMessage calls
// as a JSON array on stdout.
'use strict';
const fs = require('fs');

const pagePath = process.argv[2];
const scenario = process.argv[3];

const html = fs.readFileSync(pagePath, 'utf8');
const match = html.match(/<script>([\s\S]*?)<\/script>/);
if (!match) {
  console.error('no <script> block found in ' + pagePath);
  process.exit(1);
}
const js = match[1];

function makeElement() {
  const el = {
    className: '',
    textContent: '',
    value: '',
    src: '',
    onclick: null,
    _children: [],
    _listeners: {},
    append() { el._children.push(...arguments); },
    addEventListener(type, fn) { el._listeners[type] = fn; },
    scrollIntoView() {},
    focus() {},
  };
  Object.defineProperty(el, 'innerHTML', {
    get() { return el._innerHTML || ''; },
    // Setting innerHTML clears whatever was appended, same as the real DOM.
    set(v) { el._innerHTML = v; el._children = []; },
  });
  Object.defineProperty(el, 'children', {
    get() { return el._children; },
  });
  return el;
}

// The page reads #crumb and #list as bare globals — the way a browser
// exposes elements with an id attribute — so these must exist as globals
// before the page script runs, not just be reachable via getElementById.
const crumbEl = makeElement();
const listEl = makeElement();
const filterEl = makeElement();
global.crumb = crumbEl;
global.list = listEl;

const documentListeners = {};
global.document = {
  documentElement: { style: { setProperty() {} } },
  getElementById(id) { return id === 'filter' ? filterEl : null; },
  createElement() { return makeElement(); },
  addEventListener(type, fn) { documentListeners[type] = fn; },
};

const messages = [];
let omamacData = {};
try {
  omamacData = JSON.parse(process.env.OMAMAC_JSON || '{}');
} catch (e) {
  console.error('OMAMAC_JSON did not parse: ' + e.message);
  process.exit(1);
}

global.window = {
  OMAMAC: omamacData,
  webkit: {
    messageHandlers: {
      omamac: { postMessage(m) { messages.push(m); } },
    },
  },
};

// The page's top-level `const`/`function` declarations stay local to this
// Function body; its free references to document/window/crumb/list resolve
// against the globals set up above, same as a <script> tag in a real page.
new Function(js)();

function fireKey(key) {
  const handler = documentListeners.keydown;
  if (!handler) {
    console.error('page never registered a keydown listener');
    process.exit(1);
  }
  handler({ key, preventDefault() {} });
}

switch (scenario) {
  case 'enter-enter':
    fireKey('Enter');
    fireKey('Enter');
    break;
  case 'escape':
    fireKey('Escape');
    break;
  case 'bg-render-thrice':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('ArrowDown'); // root: Font -> Background
    fireKey('Enter');     // enter Background — first render() call
    fireKey('ArrowDown'); // second render() call, no thumbs supplied meanwhile
    fireKey('ArrowDown'); // third render() call, ditto
    break;
  default:
    console.error('unknown scenario: ' + scenario);
    process.exit(1);
}

process.stdout.write(JSON.stringify(messages));
