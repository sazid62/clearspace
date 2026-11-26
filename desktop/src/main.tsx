import React from "react";
import ReactDOM from "react-dom/client";
import "./styles.css";
import { invoke } from "@tauri-apps/api/core";
import { initPlatform } from "./platform";

// The platform (keyboard conventions, title bar) and home folder are known before anything renders.
initPlatform().then(async () => {
  const { App } = await import("./App");
  ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
  const scenario = await invoke<string | null>("selftest_mode");
  if (scenario) void import("./selftest").then((t) => t.run(scenario));
});
