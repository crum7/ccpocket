// @ts-check
/*
 * Markdown subset renderer + tiny syntax highlighter + diff renderer.
 *
 * Supported markdown:
 *   - headings h1..h3
 *   - paragraphs split by blank lines
 *   - bold / italic / inline code
 *   - fenced code blocks (with optional language)
 *   - unordered + ordered lists (one level)
 *   - blockquotes
 *   - horizontal rules (---)
 *   - markdown links [label](target) (file links open in editor)
 *   - bare file path tokens (turned into open-file links)
 *
 * Highlighting strategy: regex-driven, token-class only. We never set colors
 * inline — every token gets a CSS class and styles.css maps it to a VSCode
 * theme variable. Unknown languages fall back to plain <pre><code>.
 *
 * Diff: a fenced ```diff block is rendered line-by-line with a gutter; +/-
 * lines pick up VSCode's diff-editor background variables in CSS.
 *
 * SECURITY: every untrusted character path uses createTextNode / textContent.
 * createElement is only used for structural tags. We never call innerHTML.
 */

/** @typedef {import('../src/messages.js').WebviewToExtension} WebviewToExtension */

import { send } from './state.js';

// ---------- Inline parsing -------------------------------------------------

// Inline splitter that handles `code`, **bold**, *italic*, [label](target).
// Order matters — longer / more specific first.
const INLINE_RE = /(`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*|_[^_\n]+_|\[[^\]]+\]\([^)\s]+\))/g;
const LINK_RE = /^\[([^\]]+)\]\(([^)\s]+)\)$/;

// File-token regex used both for [link](target) parsing and bare-path detection.
// Allow common extensions; extend cautiously to avoid greedy matches.
const FILE_EXT = '(?:ts|tsx|js|jsx|mjs|cjs|dart|py|swift|kt|java|go|rs|rb|php|cs|cpp|c|h|hpp|md|json|yaml|yml|toml|html|css|scss|sh|bash|sql|xml)';
const BARE_FILE_RE = new RegExp(`[\\w./\\-]+\\.${FILE_EXT}(?::\\d+)?`, 'g');
const TARGET_FILE_RE = new RegExp(`^([\\w./\\-]+\\.${FILE_EXT})(?::(\\d+))?$`);

/**
 * Parse a markdown link target into {path, line} if it looks like a file ref.
 * Returns null otherwise (caller treats as a plain anchor).
 *
 * @param {string} target
 * @returns {{ path: string, line?: number } | null}
 */
function parseFileTarget(target) {
  if (/^https?:\/\//i.test(target)) return null;
  if (target.startsWith('#') || target.startsWith('mailto:')) return null;
  const m = target.match(TARGET_FILE_RE);
  if (!m) {
    // Bare absolute / relative path without extension match? Best-effort:
    // accept paths with a slash and no protocol scheme.
    if (target.includes('/') && !target.includes(' ')) {
      const colonIdx = target.lastIndexOf(':');
      if (colonIdx > 0 && /^\d+$/.test(target.slice(colonIdx + 1))) {
        return { path: target.slice(0, colonIdx), line: Number(target.slice(colonIdx + 1)) };
      }
      return { path: target };
    }
    return null;
  }
  return { path: m[1], line: m[2] ? Number(m[2]) : undefined };
}

/**
 * Build a click-to-open <a> for a file path.
 * @param {string} label
 * @param {string} path
 * @param {number | undefined} line
 */
function makeFileLink(label, path, line) {
  const a = document.createElement('a');
  a.className = 'file-link';
  a.textContent = label;
  a.href = '#';
  a.dataset.path = path;
  if (line !== undefined) a.dataset.line = String(line);
  a.addEventListener('click', (ev) => {
    ev.preventDefault();
    /** @type {WebviewToExtension} */
    const msg = line !== undefined
      ? { type: 'open-file', path, line }
      : { type: 'open-file', path };
    send(msg);
  });
  return a;
}

/**
 * Append text into `parent`, turning bare file-path tokens into open-file links.
 * @param {Node} parent
 * @param {string} text
 */
function appendTextWithFileLinks(parent, text) {
  if (!text) return;
  BARE_FILE_RE.lastIndex = 0;
  let last = 0;
  let m;
  while ((m = BARE_FILE_RE.exec(text)) !== null) {
    if (m.index > last) {
      parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    }
    const token = m[0];
    const colonIdx = token.lastIndexOf(':');
    let path = token;
    let line;
    if (colonIdx > 0 && /^\d+$/.test(token.slice(colonIdx + 1))) {
      path = token.slice(0, colonIdx);
      line = Number(token.slice(colonIdx + 1));
    }
    parent.appendChild(makeFileLink(token, path, line));
    last = m.index + token.length;
  }
  if (last < text.length) {
    parent.appendChild(document.createTextNode(text.slice(last)));
  }
}

/**
 * Render inline markdown content (bold/italic/code/links + file tokens).
 * @param {HTMLElement} parent
 * @param {string} text
 */
export function renderInline(parent, text) {
  const parts = text.split(INLINE_RE);
  for (const part of parts) {
    if (!part) continue;
    if (part.startsWith('`') && part.endsWith('`') && part.length >= 2) {
      const code = document.createElement('code');
      code.textContent = part.slice(1, -1);
      parent.appendChild(code);
      continue;
    }
    if (part.startsWith('**') && part.endsWith('**') && part.length >= 4) {
      const b = document.createElement('strong');
      renderInline(b, part.slice(2, -2));
      parent.appendChild(b);
      continue;
    }
    if (
      ((part.startsWith('*') && part.endsWith('*')) ||
        (part.startsWith('_') && part.endsWith('_'))) &&
      part.length >= 2
    ) {
      const i = document.createElement('em');
      renderInline(i, part.slice(1, -1));
      parent.appendChild(i);
      continue;
    }
    const linkMatch = part.match(LINK_RE);
    if (linkMatch) {
      const label = linkMatch[1];
      const target = linkMatch[2];
      const file = parseFileTarget(target);
      if (file) {
        parent.appendChild(makeFileLink(label, file.path, file.line));
      } else {
        // Non-file URL: render as plain text (CSP blocks anchor navigation).
        parent.appendChild(document.createTextNode(label));
      }
      continue;
    }
    appendTextWithFileLinks(parent, part);
  }
}

// ---------- Syntax highlighting -------------------------------------------

/**
 * Per-language regex sets. Each entry produces tokens that we map to CSS
 * classes (no inline color). The order in the array is significant — earlier
 * patterns win when matches overlap.
 *
 * @typedef {Object} LangSpec
 * @property {RegExp[]} comments    line / block comment patterns
 * @property {RegExp[]} strings     string-literal patterns (single matches)
 * @property {string[]} keywords    bare-word keywords
 * @property {RegExp[]} numbers     numeric literal patterns
 * @property {RegExp[]} [types]     type / class-name patterns (optional)
 */

/** @type {Record<string, LangSpec>} */
const LANGS = {
  js: {
    comments: [/\/\/[^\n]*/g, /\/\*[\s\S]*?\*\//g],
    strings: [/"(?:[^"\\\n]|\\.)*"/g, /'(?:[^'\\\n]|\\.)*'/g, /`(?:[^`\\]|\\.)*`/g],
    keywords: [
      'const', 'let', 'var', 'function', 'return', 'if', 'else', 'for', 'while',
      'do', 'switch', 'case', 'break', 'continue', 'class', 'extends', 'new',
      'this', 'super', 'import', 'export', 'from', 'as', 'default', 'try',
      'catch', 'finally', 'throw', 'typeof', 'instanceof', 'in', 'of', 'await',
      'async', 'yield', 'true', 'false', 'null', 'undefined', 'void',
    ],
    numbers: [/\b\d+(?:\.\d+)?\b/g],
  },
  ts: {
    comments: [/\/\/[^\n]*/g, /\/\*[\s\S]*?\*\//g],
    strings: [/"(?:[^"\\\n]|\\.)*"/g, /'(?:[^'\\\n]|\\.)*'/g, /`(?:[^`\\]|\\.)*`/g],
    keywords: [
      'const', 'let', 'var', 'function', 'return', 'if', 'else', 'for', 'while',
      'do', 'switch', 'case', 'break', 'continue', 'class', 'extends', 'new',
      'this', 'super', 'import', 'export', 'from', 'as', 'default', 'try',
      'catch', 'finally', 'throw', 'typeof', 'instanceof', 'in', 'of', 'await',
      'async', 'yield', 'true', 'false', 'null', 'undefined', 'void',
      'interface', 'type', 'enum', 'namespace', 'declare', 'readonly', 'public',
      'private', 'protected', 'abstract', 'implements', 'keyof', 'infer',
    ],
    numbers: [/\b\d+(?:\.\d+)?\b/g],
  },
  python: {
    comments: [/#[^\n]*/g],
    strings: [
      /"""[\s\S]*?"""/g,
      /'''[\s\S]*?'''/g,
      /"(?:[^"\\\n]|\\.)*"/g,
      /'(?:[^'\\\n]|\\.)*'/g,
    ],
    keywords: [
      'def', 'class', 'return', 'if', 'elif', 'else', 'for', 'while', 'break',
      'continue', 'pass', 'import', 'from', 'as', 'try', 'except', 'finally',
      'raise', 'with', 'yield', 'lambda', 'global', 'nonlocal', 'in', 'is',
      'not', 'and', 'or', 'True', 'False', 'None', 'self', 'async', 'await',
    ],
    numbers: [/\b\d+(?:\.\d+)?\b/g],
  },
  dart: {
    comments: [/\/\/[^\n]*/g, /\/\*[\s\S]*?\*\//g],
    strings: [/"(?:[^"\\\n]|\\.)*"/g, /'(?:[^'\\\n]|\\.)*'/g],
    keywords: [
      'var', 'final', 'const', 'void', 'int', 'double', 'String', 'bool',
      'dynamic', 'List', 'Map', 'Set', 'class', 'extends', 'implements', 'with',
      'mixin', 'enum', 'abstract', 'static', 'late', 'required', 'factory',
      'this', 'super', 'new', 'return', 'if', 'else', 'for', 'while', 'do',
      'switch', 'case', 'break', 'continue', 'try', 'catch', 'finally',
      'throw', 'rethrow', 'async', 'await', 'yield', 'import', 'export',
      'library', 'part', 'as', 'show', 'hide', 'true', 'false', 'null',
    ],
    numbers: [/\b\d+(?:\.\d+)?\b/g],
  },
  swift: {
    comments: [/\/\/[^\n]*/g, /\/\*[\s\S]*?\*\//g],
    strings: [/"(?:[^"\\\n]|\\.)*"/g],
    keywords: [
      'let', 'var', 'func', 'class', 'struct', 'enum', 'protocol', 'extension',
      'guard', 'if', 'else', 'for', 'while', 'switch', 'case', 'default',
      'break', 'continue', 'return', 'in', 'is', 'as', 'self', 'super', 'init',
      'deinit', 'public', 'private', 'fileprivate', 'internal', 'open',
      'static', 'final', 'override', 'lazy', 'mutating', 'inout', 'throws',
      'rethrows', 'try', 'catch', 'do', 'defer', 'import', 'true', 'false',
      'nil', 'async', 'await', 'actor',
    ],
    numbers: [/\b\d+(?:\.\d+)?\b/g],
  },
  json: {
    comments: [],
    strings: [/"(?:[^"\\\n]|\\.)*"/g],
    keywords: ['true', 'false', 'null'],
    numbers: [/-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/g],
  },
  bash: {
    comments: [/#[^\n]*/g],
    strings: [/"(?:[^"\\\n]|\\.)*"/g, /'(?:[^'\\\n]|\\.)*'/g],
    keywords: [
      'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'do', 'done', 'case',
      'esac', 'in', 'function', 'return', 'echo', 'export', 'local', 'source',
      'set', 'unset', 'cd', 'pushd', 'popd', 'pwd',
    ],
    numbers: [/\b\d+\b/g],
  },
};

// Aliases.
LANGS.javascript = LANGS.js;
LANGS.typescript = LANGS.ts;
LANGS.py = LANGS.python;
LANGS.sh = LANGS.bash;
LANGS.shell = LANGS.bash;
LANGS.zsh = LANGS.bash;
LANGS.yaml = {
  comments: [/#[^\n]*/g],
  strings: [/"(?:[^"\\\n]|\\.)*"/g, /'(?:[^'\\\n]|\\.)*'/g],
  keywords: ['true', 'false', 'null', 'yes', 'no'],
  numbers: [/\b\d+(?:\.\d+)?\b/g],
};
LANGS.yml = LANGS.yaml;

/**
 * Tokenize `src` into spans of {start,end,cls}. Tokens never overlap — the
 * algorithm reserves earlier-priority ranges so later passes skip them.
 *
 * @param {string} src
 * @param {LangSpec} lang
 */
function tokenize(src, lang) {
  /** @type {Array<{start:number,end:number,cls:string}>} */
  const tokens = [];

  /** @param {number} start @param {number} end */
  const overlaps = (start, end) =>
    tokens.some((t) => start < t.end && end > t.start);

  /** @param {RegExp[]} patterns @param {string} cls */
  const runPatterns = (patterns, cls) => {
    for (const re of patterns) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(src)) !== null) {
        const start = m.index;
        const end = start + m[0].length;
        if (!overlaps(start, end)) {
          tokens.push({ start, end, cls });
        }
        if (m[0].length === 0) re.lastIndex++;
      }
    }
  };

  // Comments first (they swallow strings/keywords inside them).
  runPatterns(lang.comments, 'hl-comment');
  // Then strings.
  runPatterns(lang.strings, 'hl-string');
  // Numbers.
  runPatterns(lang.numbers, 'hl-number');
  // Keywords: build one alternation regex with word boundaries.
  if (lang.keywords.length > 0) {
    const escaped = lang.keywords.map((k) => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    const re = new RegExp(`\\b(?:${escaped.join('|')})\\b`, 'g');
    runPatterns([re], 'hl-keyword');
  }

  tokens.sort((a, b) => a.start - b.start);
  return tokens;
}

/**
 * Highlight `src` into the given <code> element. Falls back to plain text
 * when the language isn't recognized.
 *
 * @param {HTMLElement} codeEl
 * @param {string} src
 * @param {string} [lang]
 */
export function highlightInto(codeEl, src, lang) {
  while (codeEl.firstChild) codeEl.removeChild(codeEl.firstChild);
  const spec = lang ? LANGS[lang.toLowerCase()] : undefined;
  if (!spec) {
    codeEl.appendChild(document.createTextNode(src));
    return;
  }
  const tokens = tokenize(src, spec);
  let cursor = 0;
  for (const t of tokens) {
    if (t.start > cursor) {
      codeEl.appendChild(document.createTextNode(src.slice(cursor, t.start)));
    }
    const span = document.createElement('span');
    span.className = t.cls;
    span.textContent = src.slice(t.start, t.end);
    codeEl.appendChild(span);
    cursor = t.end;
  }
  if (cursor < src.length) {
    codeEl.appendChild(document.createTextNode(src.slice(cursor)));
  }
}

// ---------- Diff renderer --------------------------------------------------

/**
 * Render a unified-diff body into the given container as a table-ish list of
 * lines with +/- gutters. Hunk headers (@@) are kept as a dim styled row.
 *
 * @param {HTMLElement} container
 * @param {string} src
 */
export function renderDiff(container, src) {
  const wrap = document.createElement('div');
  wrap.className = 'diff';
  const lines = src.split('\n');
  for (const line of lines) {
    const row = document.createElement('div');
    row.className = 'diff-line';
    const gutter = document.createElement('span');
    gutter.className = 'diff-gutter';
    const body = document.createElement('span');
    body.className = 'diff-body';
    if (line.startsWith('+++') || line.startsWith('---')) {
      row.classList.add('diff-header');
      gutter.textContent = '';
      body.textContent = line;
    } else if (line.startsWith('@@')) {
      row.classList.add('diff-hunk');
      gutter.textContent = '';
      body.textContent = line;
    } else if (line.startsWith('+')) {
      row.classList.add('diff-add');
      gutter.textContent = '+';
      body.textContent = line.slice(1);
    } else if (line.startsWith('-')) {
      row.classList.add('diff-del');
      gutter.textContent = '−';
      body.textContent = line.slice(1);
    } else {
      gutter.textContent = ' ';
      body.textContent = line.startsWith(' ') ? line.slice(1) : line;
    }
    row.appendChild(gutter);
    row.appendChild(body);
    wrap.appendChild(row);
  }
  container.appendChild(wrap);
}

// ---------- Block markdown -------------------------------------------------

const CODE_FENCE_RE = /^```(\S*)\s*$/;

/**
 * Render a markdown subset into the given container, replacing its contents.
 *
 * @param {HTMLElement} container
 * @param {string} text
 */
export function renderMarkdown(container, text) {
  // Clear without using innerHTML.
  while (container.firstChild) container.removeChild(container.firstChild);

  const lines = (text ?? '').split('\n');
  let i = 0;
  /** @type {string[]} */
  let paragraph = [];

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    const p = document.createElement('p');
    renderInline(p, paragraph.join(' '));
    container.appendChild(p);
    paragraph = [];
  };

  /** @param {'ul'|'ol'} kind @param {string[]} items */
  const flushList = (kind, items) => {
    const list = document.createElement(kind);
    list.className = 'md-list';
    for (const item of items) {
      const li = document.createElement('li');
      renderInline(li, item);
      list.appendChild(li);
    }
    container.appendChild(list);
  };

  while (i < lines.length) {
    const line = lines[i];

    // Fenced code block.
    const fence = line.match(CODE_FENCE_RE);
    if (fence) {
      flushParagraph();
      const lang = (fence[1] || '').toLowerCase();
      const buf = [];
      i++;
      while (i < lines.length && !CODE_FENCE_RE.test(lines[i])) {
        buf.push(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // skip closing fence
      const body = buf.join('\n');
      if (lang === 'diff') {
        const wrap = document.createElement('div');
        wrap.className = 'codeblock codeblock-diff';
        renderDiff(wrap, body);
        container.appendChild(wrap);
      } else {
        const pre = document.createElement('pre');
        pre.className = 'codeblock';
        const code = document.createElement('code');
        if (lang) code.dataset.lang = lang;
        highlightInto(code, body, lang);
        pre.appendChild(code);
        container.appendChild(pre);
      }
      continue;
    }

    // Headings.
    const h = line.match(/^(#{1,3})\s+(.*)$/);
    if (h) {
      flushParagraph();
      const level = h[1].length;
      const el = document.createElement(`h${level}`);
      el.className = `md-h${level}`;
      renderInline(el, h[2]);
      container.appendChild(el);
      i++;
      continue;
    }

    // Horizontal rule.
    if (/^---+\s*$/.test(line)) {
      flushParagraph();
      container.appendChild(document.createElement('hr'));
      i++;
      continue;
    }

    // Blockquote (consecutive `>` lines).
    if (/^>\s?/.test(line)) {
      flushParagraph();
      const buf = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        buf.push(lines[i].replace(/^>\s?/, ''));
        i++;
      }
      const quote = document.createElement('blockquote');
      quote.className = 'md-quote';
      // Recurse into the quote contents so nested code etc. still works.
      renderMarkdown(quote, buf.join('\n'));
      container.appendChild(quote);
      continue;
    }

    // Unordered list.
    if (/^[-*+]\s+/.test(line)) {
      flushParagraph();
      /** @type {string[]} */
      const items = [];
      while (i < lines.length && /^[-*+]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^[-*+]\s+/, ''));
        i++;
      }
      flushList('ul', items);
      continue;
    }

    // Ordered list.
    if (/^\d+[.)]\s+/.test(line)) {
      flushParagraph();
      /** @type {string[]} */
      const items = [];
      while (i < lines.length && /^\d+[.)]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\d+[.)]\s+/, ''));
        i++;
      }
      flushList('ol', items);
      continue;
    }

    // Blank line ⇒ paragraph break.
    if (line.trim() === '') {
      flushParagraph();
    } else {
      paragraph.push(line);
    }
    i++;
  }
  flushParagraph();
}
