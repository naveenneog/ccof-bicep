import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { HELP } from "../help.ts";
import { Button, Icon } from "./ui.tsx";

interface Step { element: HTMLElement; title: string; description: string }

function stepsFor(topic: string): Step[] {
  const help = HELP[topic] ?? HELP.overview;
  const elements = document.querySelectorAll<HTMLElement>("#main .page-header, #main .filter-bar, #main .panel, #main .section, #main .fieldset");
  return [...elements].filter((el) => el.getBoundingClientRect().width > 0).map((element) => {
    const title = element.querySelector("h1,h2,h3,legend")?.textContent?.trim() ||
      (element.classList.contains("filter-bar") ? "Page filters" : help.title);
    const context = element.querySelector(".section-desc,.page-subtitle,.hint")?.textContent?.trim();
    return { element, title, description: context || help.figures?.find(([name]) => title.toLowerCase().includes(name.toLowerCase()))?.[1] || help.summary };
  });
}

export function GuidedHelp({ topic, onClose }: { topic: string; onClose: () => void }) {
  const [steps] = useState(() => stepsFor(topic));
  const [index, setIndex] = useState(0);
  const [box, setBox] = useState({ x: 0, y: 0, width: 0, height: 0 });
  const panel = useRef<HTMLDivElement>(null);
  const mask = useId().replace(/:/g, "");
  const step = steps[index];
  const topicHelp = HELP[topic] ?? HELP.overview;
  useEffect(() => {
    const previous = document.activeElement;
    panel.current?.querySelector<HTMLButtonElement>("button")?.focus();
    return () => { if (previous instanceof HTMLElement && previous.isConnected) previous.focus(); };
  }, []);
  useEffect(() => {
    step?.element.scrollIntoView({ block: "center", behavior: "instant" });
    const measure = () => {
      const rect = step?.element.getBoundingClientRect();
      if (rect) setBox({ x: Math.max(0, rect.x - 4), y: Math.max(0, rect.y - 4),
        width: Math.min(innerWidth - Math.max(0, rect.x - 4), rect.width + 8), height: Math.min(innerHeight, rect.height + 8) });
    };
    measure();
    addEventListener("resize", measure); addEventListener("scroll", measure, true);
    return () => { removeEventListener("resize", measure); removeEventListener("scroll", measure, true); };
  }, [index, step]);
  return createPortal(<div className="guided-overlay" role="dialog" aria-modal="true" aria-labelledby="guided-title"
    onKeyDown={(e) => {
      if (e.key === "Escape") { e.preventDefault(); onClose(); }
      if (e.key === "Tab") {
        const buttons = [...(panel.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? [])];
        const first = buttons[0], last = buttons.at(-1);
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last?.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first?.focus(); }
      }
    }}>
    <svg className="guided-spotlight" width="100%" height="100%" aria-hidden="true">
      <defs><mask id={mask}><rect width="100%" height="100%" fill="white" />
        {step && <rect x={box.x} y={box.y} width={box.width} height={box.height} rx="8" fill="black" />}</mask></defs>
      <rect width="100%" height="100%" className="guided-shade" mask={`url(#${mask})`} />
      {step && <rect x={box.x} y={box.y} width={box.width} height={box.height} rx="8" className="guided-ring" />}
    </svg>
    <div ref={panel} className="guided-panel">
      <div className="panel-head"><h2 id="guided-title">Help: {step?.title ?? topicHelp.title}</h2>
        <button className="icon-btn" aria-label="Close guided help" onClick={onClose}><Icon name="close" /></button></div>
      <p>{step?.description ?? topicHelp.summary}</p>
      {topicHelp.permissions && <details><summary>Required permissions</summary><ul>{topicHelp.permissions.map((p) => <li key={p}>{p}</li>)}</ul></details>}
      <div className="guided-targets" aria-label="Explain a page section">
        {steps.map((s, i) => <button key={i} className="btn btn-small" aria-pressed={index === i} onClick={() => setIndex(i)}>{s.title}</button>)}
      </div>
      <div className="form-actions"><span>{steps.length ? `${index + 1} of ${steps.length}` : "Page help"}</span>
        <Button size="small" disabled={index === 0} onClick={() => setIndex(index - 1)}>Previous section</Button>
        <Button size="small" disabled={index >= steps.length - 1} onClick={() => setIndex(index + 1)}>Next section</Button>
        <Button size="small" onClick={onClose}>Done</Button>
      </div>
    </div>
  </div>, document.body);
}
