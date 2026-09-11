// dsh-vision / dsh-computer-use — browser half (hand-written bundle, no build step).
//
// Renders a status pill in the conversation composer dock while the
// computer-use overlay is running: live cursor mode (待命/移动/输入/点击),
// the Esc-cancel state, and a 停止 button that writes the cancel flag.
// All data flows through the host's /api/dsh-computer-use routes.

window.__ModuleLoader__.load({
  id: "dsh-vision",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
    let react = require("react");
    let jsx = require("react/jsx-runtime");

    const API_STATE = "/api/dsh-computer-use/state";
    const API_STOP = "/api/dsh-computer-use/stop";

    const MODE_META = {
      idle: { label: "待命", color: "#60a5fa" },
      moving: { label: "移动", color: "#3b82f6" },
      typing: { label: "输入", color: "#22d3ee" },
      clicking: { label: "点击", color: "#fbbf24" },
    };

    function badgeStyle(color, dim) {
      return {
        display: "inline-flex",
        alignItems: "center",
        gap: "6px",
        height: "22px",
        padding: "0 10px",
        borderRadius: "11px",
        border: `1px solid ${dim ? "rgba(148,163,184,0.35)" : color + "66"}`,
        background: dim ? "rgba(148,163,184,0.08)" : color + "1f",
        color: dim ? "#94a3b8" : color,
        font: "500 11px/1 system-ui, 'Microsoft YaHei UI', sans-serif",
        userSelect: "none",
        whiteSpace: "nowrap",
      };
    }

    /** Composer-dock pill: live computer-use state + stop button. */
    function ComputerUseBadge() {
      const [state, setState] = react.useState(null);
      const [busy, setBusy] = react.useState(false);
      react.useEffect(() => {
        let alive = true;
        let timer;
        const tick = async () => {
          try {
            const r = await fetch(API_STATE, { cache: "no-store" });
            const j = await r.json();
            if (alive) setState(j);
          } catch {
            if (alive) setState(null);
          }
          if (alive) timer = setTimeout(tick, 1200);
        };
        tick();
        return () => { alive = false; clearTimeout(timer); };
      }, []);
      if (!state || !state.overlay) return null;
      const mode = state.cancel ? "cancelled" : (state.mode || "idle");
      const meta = MODE_META[mode] || { label: mode, color: "#f87171" };
      const dim = Boolean(state.cancel);
      const stop = async () => {
        setBusy(true);
        try { await fetch(API_STOP, { method: "POST" }); } catch {}
        setBusy(false);
      };
      return jsx.jsxs("div", {
        style: badgeStyle(dim ? "#f87171" : meta.color, dim),
        title: `computer-use overlay ${state.overlay} · mode=${mode} · ${state.toolkit || ""}`,
        children: [
          jsx.jsx("span", {
            style: {
              width: "7px", height: "7px", borderRadius: "50%",
              background: dim ? "#f87171" : meta.color,
              boxShadow: `0 0 6px ${dim ? "#f87171" : meta.color}`,
              animation: mode === "idle" ? "none" : "pulse 1.2s ease-in-out infinite",
            },
          }),
          jsx.jsx("span", { children: state.cancel ? "已取消" : `CU ${meta.label}` }),
          jsx.jsx("button", {
            onClick: stop,
            disabled: busy || dim,
            style: {
              border: "none", background: "transparent", cursor: "pointer",
              color: "inherit", font: "inherit", padding: "0 2px", opacity: busy ? 0.5 : 0.85,
            },
            children: "停止",
          }),
        ],
      });
    }

    const inject = ["slots"];
    function apply(ctx) {
      ctx.slots.inject("conversation.composer.dock", () => ctx.slots.register({
        name: "conversation.composer.dock",
        id: "computer-use",
        order: 210,
        inject: () => ({}),
      }, ComputerUseBadge));
      ctx.effect(() => () => { /* fiber-scoped */ }, "dsh-vision: ui");
    }
    exports.apply = apply;
    exports.inject = inject;
    exports.ComputerUseBadge = ComputerUseBadge;
    return module.exports;
  },
});
