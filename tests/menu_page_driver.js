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
//            bg-select-apply (root -> Background via the coverflow, moves
//            the selection with ArrowRight — the coverflow's own key —
//            then applies it, to prove entering Background requests
//            previews and Enter posts apply/bg for whichever item is
//            selected, not just index 0).
//            type-then-report (types "the" via the document-level keydown
//            handler — there is no visible input box, the header line
//            doubles as the search display — then reports the header's
//            text/class instead of the posted messages).
// For every scenario but type-then-report, prints the captured
// window.webkit.messageHandlers.omamac.postMessage calls as a JSON array on
// stdout. type-then-report instead prints a JSON object
// {messages, headText, headClass}.
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

// The page reads #hdr, #list, #card and #cv as bare globals — the way a
// browser exposes elements with an id attribute — so these must exist as
// globals before the page script runs, not just be reachable via
// getElementById. #card is the 300px root/theme/font menu; #cv is the
// Background-level coverflow strip — the page toggles `.hidden` on
// whichever one isn't showing. There is no #filter element any more: the
// header line (#hdr) doubles as the search display, so the page never
// calls document.getElementById.
const hdrEl = makeElement();
const listEl = makeElement();
const cardEl = makeElement();
const cvEl = makeElement();
global.hdr = hdrEl;
global.list = listEl;
global.card = cardEl;
global.cv = cvEl;

const documentListeners = {};
global.document = {
  documentElement: { style: { setProperty() {} } },
  // Deliberately returns null for everything: the restyled page has no
  // remaining getElementById call, so if one shows up here it means the
  // page regressed to needing an element this shim doesn't provide, and
  // this should fail loudly rather than silently returning a stand-in.
  getElementById() { return null; },
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
// Function body; its free references to document/window/hdr/list resolve
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
  case 'bg-select-apply':
    fireKey('ArrowDown');  // root: Theme -> Font
    fireKey('ArrowDown');  // root: Font -> Background
    fireKey('Enter');      // enter Background (coverflow), sel resets to 0
    fireKey('ArrowRight'); // move selection to the second item, coverflow-style
    fireKey('Enter');      // apply the now-selected (second) item
    break;
  case 'type-then-report':
    fireKey('t');
    fireKey('h');
    fireKey('e');
    break;
  default:
    console.error('unknown scenario: ' + scenario);
    process.exit(1);
}

if (scenario === 'type-then-report') {
  process.stdout.write(JSON.stringify({
    messages,
    headText: hdrEl.textContent,
    headClass: hdrEl.className,
  }));
} else {
  process.stdout.write(JSON.stringify(messages));
}
