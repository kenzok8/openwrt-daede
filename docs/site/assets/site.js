// daede 文档站交互：主题、手机目录、站内搜索。无第三方依赖。
(function () {
  'use strict';

  var THEME_KEY = 'daede-docs-theme';
  var root = document.documentElement;

  function applyTheme(theme) {
    if (theme) root.setAttribute('data-theme', theme);
    else root.removeAttribute('data-theme');
    var toggle = document.getElementById('theme-toggle');
    if (toggle) toggle.setAttribute('aria-pressed', String(theme === 'dark'));
  }

  try {
    applyTheme(localStorage.getItem(THEME_KEY));
  } catch (e) {}

  document.addEventListener('click', function (event) {
    var toggle = event.target.closest('#theme-toggle');
    if (toggle) {
      var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      try {
        localStorage.setItem(THEME_KEY, next);
      } catch (e) {}
      applyTheme(next);
      return;
    }

    var menu = event.target.closest('#menu-toggle');
    if (menu) {
      var sidebar = document.getElementById('sidebar');
      if (!sidebar) return;
      var open = sidebar.classList.toggle('open');
      menu.setAttribute('aria-expanded', String(open));
    }
  });

  // ── 站内搜索 ──
  var overlay = document.getElementById('search');
  var input = document.getElementById('search-input');
  var results = document.getElementById('search-results');
  var index = null;
  var active = -1;

  function loadIndex() {
    if (index) return Promise.resolve(index);
    return fetch('search-index.json')
      .then(function (response) {
        return response.ok ? response.json() : [];
      })
      .then(function (data) {
        index = data;
        return index;
      })
      .catch(function () {
        index = [];
        return index;
      });
  }

  function openSearch() {
    if (!overlay) return;
    overlay.hidden = false;
    loadIndex().then(function () {
      if (input) {
        input.value = '';
        input.focus();
      }
      render('');
    });
  }

  function closeSearch() {
    if (!overlay) return;
    overlay.hidden = true;
    active = -1;
  }

  function score(entry, needle) {
    var hits = [];
    if (entry.title.toLowerCase().indexOf(needle) >= 0) hits.push({ url: entry.page, label: entry.title, kind: entry.group });
    entry.headings.forEach(function (heading) {
      if (heading.text.toLowerCase().indexOf(needle) >= 0) {
        hits.push({ url: entry.page + '#' + heading.id, label: heading.text, kind: entry.title });
      }
    });
    return hits;
  }

  function render(query) {
    if (!results) return;
    var needle = query.trim().toLowerCase();
    results.innerHTML = '';
    active = -1;
    if (!needle || !index) return;

    var hits = [];
    index.forEach(function (entry) {
      hits = hits.concat(score(entry, needle));
      if (hits.length >= 24) return;
    });
    if (!hits.length && index) {
      index.forEach(function (entry) {
        if (hits.length >= 8) return;
        if (entry.text.toLowerCase().indexOf(needle) >= 0) hits.push({ url: entry.page, label: entry.title, kind: '正文命中 · ' + entry.group });
      });
    }

    hits.slice(0, 24).forEach(function (hit) {
      var item = document.createElement('li');
      var link = document.createElement('a');
      link.href = hit.url;
      link.textContent = hit.label;
      var meta = document.createElement('small');
      meta.textContent = hit.kind;
      link.appendChild(meta);
      item.appendChild(link);
      results.appendChild(item);
    });
  }

  document.addEventListener('click', function (event) {
    if (event.target.closest('[data-search-open]')) {
      openSearch();
      return;
    }
    if (event.target.closest('[data-search-close]')) {
      closeSearch();
      return;
    }
    if (overlay && !overlay.hidden && event.target === overlay) closeSearch();
  });

  document.addEventListener('input', function (event) {
    if (event.target === input) render(input.value);
  });

  document.addEventListener('keydown', function (event) {
    var isK = event.key === 'k' || event.key === 'K';
    if (isK && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      if (overlay && overlay.hidden) openSearch();
      else closeSearch();
      return;
    }
    if (event.key === 'Escape' && overlay && !overlay.hidden) {
      closeSearch();
      return;
    }
    if (overlay && overlay.hidden) return;
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp' && event.key !== 'Enter') return;

    var links = results ? Array.prototype.slice.call(results.querySelectorAll('a')) : [];
    if (!links.length) return;
    if (event.key === 'Enter' && active >= 0) {
      links[active].click();
      return;
    }
    event.preventDefault();
    active = event.key === 'ArrowDown' ? (active + 1) % links.length : (active + links.length - 1) % links.length;
    links.forEach(function (link, i) {
      if (i === active) link.setAttribute('data-active', 'true');
      else link.removeAttribute('data-active');
    });
    links[active].scrollIntoView({ block: 'nearest' });
  });
})();
