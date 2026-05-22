/* =========================================================================
   Whistle · theme-switcher.js
   Injects a "Safe / Playful" toggle into the Material header, persists the
   choice to localStorage, and re-applies it on every page (handles Material's
   navigation.instant which reuses the DOM).
   ========================================================================= */

(function () {
  "use strict";

  var STORAGE_KEY = "whistle-ui";
  var DEFAULT_UI = "playful";
  var root = document.documentElement;

  function get() {
    try {
      var v = localStorage.getItem(STORAGE_KEY);
      return (v === "plain" || v === "playful") ? v : DEFAULT_UI;
    } catch (e) { return DEFAULT_UI; }
  }

  function set(ui) {
    root.setAttribute("data-theme", ui);
    try { localStorage.setItem(STORAGE_KEY, ui); } catch (e) {}
    syncButtonState();
  }

  function syncButtonState() {
    var btn = document.querySelector(".w-ui-toggle");
    if (!btn) return;
    var current = root.getAttribute("data-theme") || DEFAULT_UI;
    btn.setAttribute("data-current", current);
    btn.setAttribute("aria-label",
      "UI: " + current + ". Click to switch.");
  }

  function buildToggle() {
    var btn = document.createElement("button");
    btn.className = "w-ui-toggle";
    btn.type = "button";
    btn.innerHTML =
      '<span class="w-ui-toggle__opt" data-ui="plain">Plain</span>' +
      '<span class="w-ui-toggle__opt" data-ui="playful">Playful</span>';
    btn.addEventListener("click", function (ev) {
      var clickedOpt = ev.target.closest(".w-ui-toggle__opt");
      var current = root.getAttribute("data-theme") || DEFAULT_UI;
      if (clickedOpt && clickedOpt.dataset.ui) {
        set(clickedOpt.dataset.ui);
      } else {
        set(current === "plain" ? "playful" : "plain");
      }
    });
    return btn;
  }

  function inject() {
    if (document.querySelector(".w-ui-toggle")) {
      syncButtonState();
      return;
    }
    // Drop the toggle just before the repo source widget on the right side
    // of Material's header.
    var header = document.querySelector(".md-header__inner") ||
                 document.querySelector(".md-header");
    if (!header) return;
    var source = header.querySelector(".md-header__source");
    var btn = buildToggle();
    if (source) {
      source.parentNode.insertBefore(btn, source);
    } else {
      header.appendChild(btn);
    }
    syncButtonState();
  }

  // First paint — set immediately so we don't flash
  set(get());

  // Inject on initial load
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", inject);
  } else {
    inject();
  }

  // Re-inject after Material's instant navigation (DOM is replaced)
  if (typeof document$ !== "undefined" && document$.subscribe) {
    document$.subscribe(inject);
  }
})();
