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
//            bg-unavailable-preview (root -> Background with a single item,
//            then calls window.omamacSetPreview(name, "") twice — the host
//            reporting no readable thumbnail — and reports the coverflow's
//            image state alongside the posted messages, to prove the level is
//            still requested exactly once and no broken <img> is rendered).
// For every scenario but type-then-report and bg-unavailable-preview,
// prints the captured window.webkit.messageHandlers.omamac.postMessage
// calls as a JSON array on stdout. type-then-report instead prints a JSON
// object {messages, headText, headClass}; bg-empty-preview-retry-cap prints
// {messages, hasImg}.
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
    hidden: false,
    onclick: null,
    // The coverflow sets style.left / style.zIndex per item and
    // style.setProperty('--chrome', ...) on the chrome block; record both so
    // a scenario can assert on them.
    style: { _props: {}, setProperty(k, v) { this._props[k] = v; } },
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

// The page reads its elements as bare globals — the way a browser exposes
// elements with an id attribute — so these must exist before the page
// script runs, not just be reachable via getElementById. #card is the 300px
// root/font menu; #cv is the picker overlay used by BOTH the Theme and
// Background levels, holding the coverflow strip (#cvstrip) and the chrome
// under it (#cvchrome > #cvlabel, #cvfilter). The page toggles `.hidden` on
// whichever of #card/#cv isn't showing. There is no #filter element: the
// header line (#hdr) doubles as the search display for the card levels, so
// the page never calls document.getElementById.
const hdrEl = makeElement();
const listEl = makeElement();
const cardEl = makeElement();
const cvEl = makeElement();
const stripEl = makeElement();
const chromeEl = makeElement();
const labelEl = makeElement();
const filterEl = makeElement();
global.hdr = hdrEl;
global.list = listEl;
global.card = cardEl;
global.cv = cvEl;
global.cvstrip = stripEl;
global.cvchrome = chromeEl;
global.cvlabel = labelEl;
global.cvfilter = filterEl;

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
  // Fixed so the mid-row fold is deterministic; a scenario can override it
  // via OMAMAC_VIEWPORT_H.
  innerHeight: Number(process.env.OMAMAC_VIEWPORT_H || 1080),
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

let misdeliveredReport = null;

// Walks the coverflow strip and reports what a viewer would actually see:
// which item carries the selected class, and whether an <img> was appended
// (item -> .cv-inner -> img.cv-img).
function stripReport() {
  const items = stripEl.children;
  return {
    count: items.length,
    selectedIndex: items.findIndex((it) => /(^| )on( |$)/.test(it.className)),
    withImages: items.filter((it) =>
      (it.children || []).some((inner) =>
        (inner.children || []).some((c) => c.className === 'cv-img'))).length,
    listCount: listEl.children.length,
  };
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
    fireKey('ArrowDown'); // root: Font -> Opacity
    fireKey('ArrowDown'); // root: Opacity -> Background
    fireKey('Enter');     // enter Background — first render() call
    fireKey('ArrowDown'); // second render() call, no thumbs supplied meanwhile
    fireKey('ArrowDown'); // third render() call, ditto
    break;
  case 'bg-select-apply':
    fireKey('ArrowDown');  // root: Theme -> Font
    fireKey('ArrowDown');  // root: Font -> Opacity
    fireKey('ArrowDown');  // root: Opacity -> Background
    fireKey('Enter');      // enter Background (coverflow), sel resets to 0
    fireKey('ArrowRight'); // move selection to the second item, coverflow-style
    fireKey('Enter');      // apply the now-selected (second) item
    break;
  case 'type-then-report':
    fireKey('t');
    fireKey('h');
    fireKey('e');
    break;
  case 'root-report':
    break;              // report the root level exactly as first rendered
  case 'opacity-select-apply':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('ArrowDown'); // root: Font -> Opacity
    fireKey('Enter');     // enter Opacity, landing on the current value
    fireKey('ArrowDown'); // one step down the list
    fireKey('Enter');     // apply it
    break;
  case 'opacity-open-and-report':
    fireKey('ArrowDown'); fireKey('ArrowDown'); fireKey('Enter');
    break;
  case 'font-menu-report':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('Enter');     // enter Font — a submenu of Family and Size
    break;
  case 'font-open-and-report':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('Enter');     // enter Font
    fireKey('Enter');     // Family (row 0) -> the family list
    break;
  case 'size-open-and-report':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('Enter');     // enter Font
    fireKey('ArrowDown'); // Family -> Size
    fireKey('Enter');     // enter Size
    break;
  case 'size-select-apply':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('Enter');     // enter Font
    fireKey('ArrowDown'); // Family -> Size
    fireKey('Enter');     // enter Size, landing on the current size
    fireKey('ArrowDown'); // one size up
    fireKey('Enter');     // apply it
    break;
  case 'size-then-escape':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('Enter');     // enter Font
    fireKey('ArrowDown'); // Family -> Size
    fireKey('Enter');     // enter Size
    fireKey('Escape');    // back out — must land on Font, ON the Size row
    break;
  case 'theme-select-apply':
    fireKey('Enter');      // root -> Theme (the coverflow)
    fireKey('ArrowRight'); // move one along, coverflow-style
    fireKey('Enter');      // apply whatever that leaves selected
    break;
  case 'theme-open-and-report':
    fireKey('Enter');      // root -> Theme
    break;
  case 'theme-filter-no-match':
    fireKey('Enter');      // root -> Theme
    fireKey('z');          // matches nothing
    fireKey('z');
    break;
  case 'theme-misdelivered-preview':
    fireKey('Enter');      // root -> Theme; requests a preview for "nord"
    // The host answering with the WRONG kind for that same name. Nothing in
    // the message distinguishes it except `kind`, which is exactly the point.
    global.window.omamacSetPreview('nord', 'data:image/jpeg;base64,WRONG', 'bg');
    misdeliveredReport = stripReport();
    // ...then the correct one, so the assertion below can tell "keyed by
    // kind" apart from "pushes are being dropped".
    global.window.omamacSetPreview('nord', 'data:image/jpeg;base64,RIGHT', 'theme');
    break;
  case 'bg-unavailable-preview':
    fireKey('ArrowDown'); // root: Theme -> Font
    fireKey('ArrowDown'); // root: Font -> Opacity
    fireKey('ArrowDown'); // root: Opacity -> Background
    fireKey('Enter');     // enter Background — one bulk request for the level
    // The host reporting that this item has no readable thumbnail. It must
    // not be cached (an empty src renders as a broken image) and it must not
    // provoke another batch — omamac already tried, in the one task it gets.
    global.window.omamacSetPreview('only.jpg', '');
    global.window.omamacSetPreview('only.jpg', '');
    break;
  default:
    console.error('unknown scenario: ' + scenario);
    process.exit(1);
}

// Walks the card's row list and reports what a viewer would see per row:
// the icon-column glyph, the label, and whether it is the selected row.
function listReport() {
  return listEl.children.map((row) => {
    const kids = row.children || [];
    return {
      icon: (kids[0] || {}).textContent || '',
      name: (kids[1] || {}).textContent || '',
      on: /(^| )on( |$)/.test(row.className),
    };
  });
}

if (['font-open-and-report', 'root-report', 'size-open-and-report',
     'font-menu-report', 'size-then-escape', 'opacity-open-and-report'].includes(scenario)) {
  process.stdout.write(JSON.stringify({
    messages,
    list: listReport(),
    cardHidden: cardEl.hidden,
    cvHidden: cvEl.hidden,
    cardWidth: cardEl.style._props['--card-w'],
    rowH: cardEl.style._props['--row-h'],
    rowGap: cardEl.style._props['--row-gap'],
    nameSize: cardEl.style._props['--name-size'],
    listMaxH: cardEl.style._props['--list-max-h'],
  }));
} else if (scenario === 'theme-misdelivered-preview') {
  process.stdout.write(JSON.stringify({
    messages,
    strip: {
      ...misdeliveredReport,
      withImagesAfterCorrectPush: stripReport().withImages,
    },
  }));
} else if (scenario === 'theme-open-and-report' || scenario === 'theme-filter-no-match') {
  process.stdout.write(JSON.stringify({
    messages,
    strip: stripReport(),
    cardHidden: cardEl.hidden,
    cvHidden: cvEl.hidden,
    labelText: labelEl.textContent,
    labelHidden: labelEl.hidden,
    filterText: filterEl.textContent,
    filterHidden: filterEl.hidden,
    chrome: chromeEl.style._props['--chrome'],
  }));
} else if (scenario === 'type-then-report') {
  process.stdout.write(JSON.stringify({
    messages,
    headText: hdrEl.textContent,
    headClass: hdrEl.className,
  }));
} else if (scenario === 'bg-unavailable-preview') {
  // True if any coverflow item ever got an <img class="cv-img"> appended —
  // renderCoverflow only does that when thumbs[name] is truthy, so this is
  // "did an empty preview ever get cached and rendered as a broken image".
  // The image lives inside a .cv-inner wrapper (item -> .cv-inner -> img),
  // one level deeper than .cv itself — see .cv-inner in <style> and its
  // construction in renderCoverflow.
  const hasImg = stripEl.children.some((item) =>
    (item.children || []).some((inner) =>
      (inner.children || []).some((c) => c.className === 'cv-img')));
  process.stdout.write(JSON.stringify({ messages, hasImg }));
} else {
  process.stdout.write(JSON.stringify(messages));
}
