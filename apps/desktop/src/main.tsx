import "./wdyr";
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { ErrorBoundary } from "./components/error-boundary";
import { mark } from "./lib/startup-metrics";
import { applyPlatformAttribute } from "./lib/platform";

mark("script-eval");

// CSS adapts the chrome layout and translucency per platform (macOS overlay
// titlebar vs. native decorations everywhere else).
applyPlatformAttribute();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>,
);
