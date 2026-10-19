// zstaller documentation site: theme toggle, mobile menu, heading anchors,
// "On this page", copy buttons, screenshot lightbox and search. No
// dependencies.
(function () {
  "use strict";
  var root = document.documentElement;

  // ---- Theme
  var toggle = document.querySelector(".theme-toggle");
  function currentTheme() {
    if (root.dataset.theme) return root.dataset.theme;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  if (toggle) toggle.addEventListener("click", function () {
    var next = currentTheme() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try { localStorage.setItem("zstaller-theme", next); } catch (e) {}
  });

  // ---- Mobile menu
  var menu = document.querySelector(".menu-button");
  if (menu) menu.addEventListener("click", function () {
    var open = document.body.classList.toggle("nav-open");
    menu.setAttribute("aria-expanded", open ? "true" : "false");
  });

  // ---- Heading anchors and "On this page"
  var article = document.querySelector("article");
  var toc = document.getElementById("toc");
  var headings = article ? article.querySelectorAll("h2[id], h3[id]") : [];
  headings.forEach(function (h) {
    var a = document.createElement("a");
    a.href = "#" + h.id;
    a.className = "anchor";
    a.setAttribute("aria-label", "Link to this section");
    a.textContent = "#";
    h.appendChild(a);
    if (!toc) return;
    var li = document.createElement("li");
    if (h.tagName === "H3") li.className = "sub";
    var link = document.createElement("a");
    link.href = "#" + h.id;
    link.textContent = h.firstChild.textContent;
    li.appendChild(link);
    toc.appendChild(li);
  });
  if (toc && !headings.length) toc.parentElement.classList.add("empty");
  if (toc && headings.length && "IntersectionObserver" in window) {
    var links = toc.querySelectorAll("a");
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        links.forEach(function (l) { l.classList.toggle("active", l.getAttribute("href") === "#" + e.target.id); });
      });
    }, { rootMargin: "-70px 0px -70% 0px" });
    headings.forEach(function (h) { observer.observe(h); });
  }

  // ---- Copy buttons on code blocks (not on transcripts)
  document.querySelectorAll("article pre").forEach(function (pre) {
    if (pre.closest(".term")) return;
    var wrap = pre.parentElement;
    wrap.classList.add("has-copy");
    var b = document.createElement("button");
    b.type = "button";
    b.className = "copy";
    b.textContent = "Copy";
    b.addEventListener("click", function () {
      navigator.clipboard.writeText(pre.innerText.replace(/\n$/, "")).then(function () {
        b.textContent = "Copied";
        setTimeout(function () { b.textContent = "Copy"; }, 1500);
      });
    });
    wrap.appendChild(b);
  });

  // ---- Lightbox for screenshots
  var box = document.getElementById("lightbox");
  if (box) {
    var boxImg = box.querySelector("img");
    var boxText = box.querySelector("p");
    var close = function () { box.hidden = true; document.body.style.overflow = ""; };
    document.addEventListener("click", function (e) {
      var a = e.target.closest && e.target.closest("a.zoom");
      if (!a || e.metaKey || e.ctrlKey) return;
      e.preventDefault();
      var img = a.querySelector("img");
      var fig = a.closest("figure");
      var cap = fig && fig.querySelector("figcaption");
      boxImg.src = a.href;
      boxImg.alt = img ? img.alt : "";
      boxText.textContent = a.dataset.caption || (cap ? cap.textContent : "");
      box.hidden = false;
      document.body.style.overflow = "hidden";
    });
    box.addEventListener("click", function (e) { if (e.target !== boxImg) close(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !box.hidden) close(); });
  }

  // ---- Search
  var input = document.getElementById("search-input");
  var results = document.getElementById("search-results");
  var index = null;
  var selected = -1;
  function load() {
    if (index) return Promise.resolve(index);
    return fetch(window.ZSTALLER_SEARCH).then(function (r) { return r.json(); }).then(function (d) { index = d; return d; });
  }
  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; });
  }
  function highlight(text, terms) {
    var out = escapeHtml(text);
    terms.forEach(function (t) {
      var re = new RegExp("(" + t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")", "ig");
      out = out.replace(re, "<mark>$1</mark>");
    });
    return out;
  }
  function snippet(text, terms) {
    var lower = text.toLowerCase();
    var at = -1;
    terms.some(function (t) { at = lower.indexOf(t); return at >= 0; });
    var start = Math.max(0, at - 60);
    return (start > 0 ? "…" : "") + text.substr(start, 170) + "…";
  }
  function search(q) {
    var terms = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!terms.length) return [];
    return index.map(function (p) {
      var title = p.title.toLowerCase();
      var text = p.text.toLowerCase();
      var score = 0;
      for (var i = 0; i < terms.length; i++) {
        var t = terms[i];
        var inTitle = title.indexOf(t) >= 0;
        var count = text.split(t).length - 1;
        if (!inTitle && !count) return null;
        score += (inTitle ? 20 : 0) + Math.min(count, 10);
      }
      return { page: p, score: score };
    }).filter(Boolean).sort(function (a, b) { return b.score - a.score; }).slice(0, 8).map(function (r) {
      return { url: r.page.url, title: r.page.title, snippet: snippet(r.page.text, terms), terms: terms };
    });
  }
  function render(items) {
    selected = -1;
    if (!items.length) {
      results.innerHTML = '<li><a><small>No results</small></a></li>';
    } else {
      results.innerHTML = items.map(function (r) {
        return '<li><a href="' + r.url + '"><strong>' + highlight(r.title, r.terms) + "</strong><small>" + highlight(r.snippet, r.terms) + "</small></a></li>";
      }).join("");
    }
    results.hidden = false;
  }
  if (input) {
    input.addEventListener("input", function () {
      var q = input.value.trim();
      if (q.length < 2) { results.hidden = true; return; }
      load().then(function () { render(search(q)); });
    });
    input.addEventListener("keydown", function (e) {
      var links = results.querySelectorAll("a[href]");
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (!links.length) return;
        selected = (selected + (e.key === "ArrowDown" ? 1 : -1) + links.length) % links.length;
        links.forEach(function (l, i) { l.classList.toggle("active", i === selected); });
      } else if (e.key === "Enter" && links.length) {
        window.location = links[Math.max(selected, 0)].href;
      } else if (e.key === "Escape") {
        results.hidden = true;
        input.blur();
      }
    });
    input.addEventListener("focus", function () { load(); });
    document.addEventListener("click", function (e) { if (!e.target.closest(".search")) results.hidden = true; });
    document.addEventListener("keydown", function (e) {
      if (e.key === "/" && document.activeElement !== input && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
        e.preventDefault();
        input.focus();
      }
    });
  }
})();
