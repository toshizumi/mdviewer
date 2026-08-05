/* MDViewer — レンダリング本体。
   Swift 側からは window.MDV の関数だけを呼ぶ。 */
(function () {
  'use strict';

  var content = document.getElementById('content');
  var root = document.documentElement;

  // ---------------------------------------------------------------- markdown-it

  var md = window.markdownit({
    html: true,        // 生 HTML を許可。CSP でスクリプト実行は封じてある
    linkify: true,
    breaks: false,     // GitHub の .md 表示と同じく単一改行は無視する
    typographer: false,
    highlight: function (code, lang) {
      if (window.hljs && lang && window.hljs.getLanguage(lang)) {
        try {
          return window.hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        } catch (e) { /* 落ちても素のコードとして出せばよい */ }
      }
      return '';       // 空文字を返すと markdown-it 側でエスケープしてくれる
    }
  });
  if (window.markdownitFootnote) md.use(window.markdownitFootnote);

  // ---------------------------------------------------------------- URL の解決

  // Markdown 中のパスを mdv:// スキームに載せ替える。
  //   相対パス      → mdv://doc/...  （Markdown ファイルのあるディレクトリ基準）
  //   絶対パス /... → mdv://abs/...  （ファイルシステムの絶対パス）
  //   http(s): など → そのまま
  function toResourceURL(raw) {
    if (!raw) return raw;
    if (/^[a-z][a-z0-9+.\-]*:/i.test(raw)) return raw;   // 既にスキーム付き
    if (raw.charAt(0) === '#') return raw;               // 文書内アンカー

    // 既に %xx でエンコード済みなら二重エンコードしない
    var p = /%[0-9A-Fa-f]{2}/.test(raw) ? raw : encodeURI(raw);
    if (p.charAt(0) === '/') return 'mdv://abs' + p;
    return 'mdv://doc/' + p.replace(/^\.\//, '');
  }

  // ---------------------------------------------------------------- 前処理

  // 先頭の YAML フロントマターを切り出す。
  // 冒頭の水平線を誤検出しないよう「key: value 形式の行が 1 つ以上ある」ことを条件にする。
  function splitFrontMatter(text) {
    var m = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(\r?\n|$)/.exec(text);
    if (!m || !/^[ \t]*[\w.$-]+[ \t]*:/m.test(m[1])) return { meta: null, body: text };
    return { meta: m[1], body: text.slice(m[0].length) };
  }

  // ---------------------------------------------------------------- 後処理

  function slugify(text, used) {
    var base = text.trim().toLowerCase()
      .replace(/[\s　]+/g, '-')
      .replace(/[!-\/:-@\[-`{-~！-＠［-｀｛-～、。・「」]/g, '')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '') || 'section';
    var slug = base, n = 1;
    while (used[slug]) slug = base + '-' + (++n);
    used[slug] = true;
    return slug;
  }

  function decorate(frag) {
    // 画像・リンクのパスを mdv:// に載せ替える
    frag.querySelectorAll('img[src]').forEach(function (img) {
      img.setAttribute('src', toResourceURL(img.getAttribute('src')));
    });
    frag.querySelectorAll('a[href]').forEach(function (a) {
      a.setAttribute('href', toResourceURL(a.getAttribute('href')));
    });

    // シンタックスハイライトのテーマ CSS は code.hljs を対象にしている
    frag.querySelectorAll('pre > code').forEach(function (code) {
      code.classList.add('hljs');
    });

    // 見出しに id とホバーアンカーを付ける
    var used = {};
    frag.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function (h) {
      if (!h.id) h.id = slugify(h.textContent, used);
      var a = document.createElement('a');
      a.className = 'anchor';
      a.href = '#' + h.id;
      a.textContent = '#';
      a.setAttribute('aria-hidden', 'true');
      h.insertBefore(a, h.firstChild);
    });

    // GFM のタスクリスト（- [ ] / - [x]）をチェックボックス表示にする
    frag.querySelectorAll('li').forEach(function (li) {
      var host = (li.firstElementChild && li.firstElementChild.tagName === 'P')
        ? li.firstElementChild : li;
      var node = host.firstChild;
      if (!node || node.nodeType !== 3) return;
      var m = /^\[([ xX])\]\s+/.exec(node.nodeValue);
      if (!m) return;
      node.nodeValue = node.nodeValue.slice(m[0].length);
      li.classList.add('task-item');
      if (m[1] !== ' ') li.classList.add('done');
      var box = document.createElement('span');
      box.className = 'task-box';
      li.insertBefore(box, li.firstChild);
    });

    // 横に長い表は、はみ出さずスクロールできるように包む
    frag.querySelectorAll('table').forEach(function (table) {
      var wrap = document.createElement('div');
      wrap.className = 'table-scroll';
      table.parentNode.insertBefore(wrap, table);
      wrap.appendChild(table);
    });
  }

  // ---------------------------------------------------------------- 描画

  var pendingImages = 0;
  var readyResolvers = [];

  function noteImageSettled() {
    if (--pendingImages > 0) return;
    var rs = readyResolvers;
    readyResolvers = [];
    rs.forEach(function (r) { r(); });
  }

  function watchImages() {
    var imgs = content.querySelectorAll('img');
    pendingImages = 0;
    imgs.forEach(function (img) {
      if (img.complete) {
        if (img.naturalWidth === 0) markBroken(img);
        return;
      }
      pendingImages++;
      img.addEventListener('load', noteImageSettled, { once: true });
      img.addEventListener('error', function () {
        markBroken(img);
        noteImageSettled();
      }, { once: true });
    });
  }

  function markBroken(img) {
    img.classList.add('broken');
    if (!img.alt) img.alt = '画像を読み込めません: ' + decodeURI(img.getAttribute('src') || '');
  }

  function render(text) {
    clearFind();
    var scroll = window.scrollY;

    var split = splitFrontMatter(text);
    var html = md.render(split.body);

    // template の中身は不活性なので、この時点では画像の読み込みが走らない。
    // mdv:// に書き換えてから本文に差し込むことで、無駄なリクエストを出さずに済む。
    var tpl = document.createElement('template');
    tpl.innerHTML = html;
    decorate(tpl.content);

    content.textContent = '';
    if (split.meta !== null) {
      var box = document.createElement('div');
      box.className = 'frontmatter';
      box.textContent = split.meta.trim();
      content.appendChild(box);
    }
    content.appendChild(tpl.content);

    watchImages();
    // 再読み込み時にスクロール位置を保つ
    window.scrollTo(0, scroll);
  }

  function showEmptyState(message) {
    clearFind();
    content.textContent = '';
    var div = document.createElement('div');
    div.className = 'empty-state';
    div.textContent = message;
    content.appendChild(div);
  }

  // ---------------------------------------------------------------- 外観

  var appearance = 'auto';
  var darkQuery = window.matchMedia('(prefers-color-scheme: dark)');

  function applyAppearance() {
    root.setAttribute('data-appearance', appearance);
    var dark = appearance === 'dark' || (appearance === 'auto' && darkQuery.matches);
    var link = document.getElementById('hl-dark');
    if (link) link.disabled = !dark;
  }
  darkQuery.addEventListener('change', applyAppearance);

  // ---------------------------------------------------------------- 文書内検索

  // window.find() はウインドウのフォーカスが検索欄に移るとハイライトが薄くなるため、
  // 自前で <mark> を差し込む方式にしている。件数も出せる。
  var hits = [];
  var hitIndex = -1;

  function clearFind() {
    if (!hits.length) return;
    hits.forEach(function (mark) {
      var parent = mark.parentNode;
      if (!parent) return;
      parent.replaceChild(document.createTextNode(mark.textContent), mark);
      parent.normalize();
    });
    hits = [];
    hitIndex = -1;
  }

  function find(query) {
    clearFind();
    if (!query) return { index: 0, total: 0 };

    var needle = query.toLowerCase();
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        var tag = node.parentNode && node.parentNode.nodeName;
        if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    var targets = [];
    for (var n = walker.nextNode(); n; n = walker.nextNode()) targets.push(n);

    targets.forEach(function (node) {
      var text = node.nodeValue;
      var lower = text.toLowerCase();
      var at = lower.indexOf(needle);
      if (at < 0) return;

      var rest = node;
      var consumed = 0;
      while (at >= 0) {
        // rest を [前半][ヒット][後半] に割って、真ん中を <mark> に差し替える
        var head = rest.splitText(at - consumed);
        var tail = head.splitText(needle.length);
        var mark = document.createElement('mark');
        mark.className = 'find-hit';
        mark.textContent = head.nodeValue;
        head.parentNode.replaceChild(mark, head);
        hits.push(mark);

        consumed = at + needle.length;
        rest = tail;
        at = lower.indexOf(needle, consumed);
      }
    });

    if (hits.length) focusHit(0);
    return { index: hits.length ? 1 : 0, total: hits.length };
  }

  function focusHit(i) {
    if (!hits.length) return;
    if (hitIndex >= 0 && hits[hitIndex]) hits[hitIndex].classList.remove('current');
    hitIndex = (i % hits.length + hits.length) % hits.length;
    var mark = hits[hitIndex];
    mark.classList.add('current');
    mark.scrollIntoView({ block: 'center', inline: 'nearest' });
  }

  function step(delta) {
    if (!hits.length) return { index: 0, total: 0 };
    focusHit(hitIndex + delta);
    return { index: hitIndex + 1, total: hits.length };
  }

  // ---------------------------------------------------------------- 印刷モード

  // 閉じている <details> は中身が紙に出ない。PDF から内容が欠け落ちないよう、
  // 印刷のあいだだけ開いておき、終わったら元に戻す。
  var temporarilyOpened = [];

  function beginPrintMode() {
    endPrintMode();
    content.querySelectorAll('details:not([open])').forEach(function (details) {
      details.open = true;
      temporarilyOpened.push(details);
    });
  }

  function endPrintMode() {
    temporarilyOpened.forEach(function (details) { details.open = false; });
    temporarilyOpened = [];
  }

  // ---------------------------------------------------------------- 公開 API

  window.MDV = {
    render: render,
    showEmptyState: showEmptyState,

    setAppearance: function (mode) {
      appearance = (mode === 'light' || mode === 'dark') ? mode : 'auto';
      applyAppearance();
    },

    setFontSize: function (px) {
      root.style.fontSize = px + 'px';
    },

    getScroll: function () { return window.scrollY; },
    setScroll: function (y) { window.scrollTo(0, y); },
    scrollToTop: function () { window.scrollTo(0, 0); },

    find: find,
    findNext: function () { return step(1); },
    findPrevious: function () { return step(-1); },
    clearFind: clearFind,

    beginPrintMode: beginPrintMode,
    endPrintMode: endPrintMode,

    // PDF 出力前に画像の読み込み完了を待つために使う
    whenReady: function () {
      if (pendingImages <= 0) return Promise.resolve(true);
      return new Promise(function (resolve) { readyResolvers.push(resolve); })
        .then(function () { return true; });
    }
  };

  applyAppearance();
})();
