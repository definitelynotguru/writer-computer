export type Platform = "macos" | "windows" | "linux";

/** Detect the desktop platform from the webview user agent. */
export function detectPlatform(): Platform {
  if (typeof navigator === "undefined") return "linux";
  const ua = navigator.userAgent;
  if (/Mac|iPhone|iPad|iPod/i.test(ua)) return "macos";
  if (/Win/i.test(ua)) return "windows";
  return "linux";
}

/** Tag the document root with the detected platform so CSS can adapt
 *  (`data-platform="macos" | "windows" | "linux"`). */
export function applyPlatformAttribute() {
  if (typeof document !== "undefined") {
    document.documentElement.dataset.platform = detectPlatform();
  }
}
