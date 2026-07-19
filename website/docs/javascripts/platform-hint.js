/* Hero install pair: highlight the pill that matches the visitor's device.
 *
 * On iOS/Android we mark the matching .w-install__opt with data-recommended
 * so a CSS rule can give it a subtle accent. UA sniffing is best-effort;
 * if detection misses (in-app browsers, masquerading, etc.) both pills just
 * render in their default state, which is the desktop behaviour anyway.
 */
(function () {
  "use strict";

  function detect() {
    var ua = navigator.userAgent || "";
    // iPad on iOS 13+ reports as Mac; check touch points to disambiguate.
    var isIPadOS =
      navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1;
    if (/iPhone|iPod/.test(ua) || isIPadOS) return "ios";
    if (/Android/.test(ua)) return "android";
    return null;
  }

  function apply() {
    var platform = detect();
    if (!platform) return;
    var opts = document.querySelectorAll(".w-install__opt");
    for (var i = 0; i < opts.length; i++) {
      var p = opts[i].getAttribute("data-platform");
      if (p === platform) {
        opts[i].setAttribute("data-recommended", "");
        opts[i].setAttribute("aria-label",
          opts[i].textContent.trim() + " (recommended for your device)");
      }
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", apply);
  } else {
    apply();
  }
})();
