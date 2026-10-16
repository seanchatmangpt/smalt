/**
 * Multi-Mode Resource Inspector (lane WS-3).
 *
 * Three-tab inspector over the Navigator's selected resource node:
 *   - "JSON" — telemetry manifest (JsonMode)
 *   - "Hex"  — raw payload bytes hex dump (HexMode)
 *   - "Attestation" — digest + signature-validity badge (AttestationMode)
 *
 * ## Props contract (integration)
 *
 * ```ts
 * interface InspectorNode {
 *   id: string;                                      // Navigator node id
 *   name: string;                                    // display name
 *   payload?: Uint8Array | Record<string, unknown>;  // raw bytes OR manifest
 * }
 * interface Attestation {
 *   digest: string;    // e.g. "sha256:…" — rendered verbatim
 *   valid: boolean;    // WS-10's verdict, presented not computed
 *   signer?: string;
 * }
 * <ResourceInspector node={selectedNode} attestation={att?} />
 * ```
 *
 * Navigator (WS-2) passes the selected node; the attestation service (WS-10)
 * supplies the `attestation` prop. This component never computes validity —
 * when `attestation` is absent, the Attestation tab shows an honest
 * unverified/refused state.
 *
 * Accessibility: WAI-ARIA tabs pattern — `role=tablist/tab/tabpanel`,
 * `aria-selected`/`aria-controls`/`aria-labelledby`, roving tabindex, and
 * Left/Right/Home/End arrow-key navigation per the ARIA Authoring Practices.
 */
import { useCallback, useId, useRef, useState } from "react";
import JsonMode from "./JsonMode";
import HexMode from "./HexMode";
import AttestationMode from "./AttestationMode";

export interface InspectorNode {
  id: string;
  name: string;
  payload?: Uint8Array | Record<string, unknown>;
}

export interface Attestation {
  digest: string;
  valid: boolean;
  signer?: string;
}

export interface ResourceInspectorProps {
  node: InspectorNode;
  attestation?: Attestation;
}

const TABS = [
  { id: "json", label: "JSON" },
  { id: "hex", label: "Hex" },
  { id: "attestation", label: "Attestation" },
] as const;

type TabId = (typeof TABS)[number]["id"];

export default function ResourceInspector({ node, attestation }: ResourceInspectorProps) {
  const [active, setActive] = useState<TabId>("json");
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);
  const baseId = useId();

  const focusTab = useCallback((index: number) => {
    const clamped = (index + TABS.length) % TABS.length;
    setActive(TABS[clamped].id);
    tabRefs.current[clamped]?.focus();
  }, []);

  const onKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      const i = TABS.findIndex((t) => t.id === active);
      switch (e.key) {
        case "ArrowRight":
          e.preventDefault();
          focusTab(i + 1);
          break;
        case "ArrowLeft":
          e.preventDefault();
          focusTab(i - 1);
          break;
        case "Home":
          e.preventDefault();
          focusTab(0);
          break;
        case "End":
          e.preventDefault();
          focusTab(TABS.length - 1);
          break;
      }
    },
    [active, focusTab],
  );

  const tabProps = { node, attestation };

  return (
    <section className="flex min-h-0 flex-col gap-2" aria-label={`Inspector for ${node.name}`}>
      <div
        role="tablist"
        aria-label="Inspector modes"
        onKeyDown={onKeyDown}
        className="flex gap-1 border-b border-neutral-800"
      >
        {TABS.map((tab, i) => {
          const selected = active === tab.id;
          return (
            <button
              key={tab.id}
              ref={(el) => {
                tabRefs.current[i] = el;
              }}
              role="tab"
              id={`${baseId}-tab-${tab.id}`}
              aria-selected={selected}
              aria-controls={`${baseId}-panel-${tab.id}`}
              tabIndex={selected ? 0 : -1}
              onClick={() => setActive(tab.id)}
              className={
                "rounded-t px-3 py-1.5 text-sm " +
                (selected
                  ? "border-x border-t border-neutral-800 bg-neutral-900 font-medium text-emerald-300"
                  : "text-neutral-400 hover:text-neutral-200")
              }
            >
              {tab.label}
            </button>
          );
        })}
      </div>
      {TABS.map((tab) => (
        <div
          key={tab.id}
          role="tabpanel"
          id={`${baseId}-panel-${tab.id}`}
          aria-labelledby={`${baseId}-tab-${tab.id}`}
          hidden={active !== tab.id}
          tabIndex={0}
          className="min-h-0 flex-1 overflow-auto"
        >
          {tab.id === "json" && <JsonMode {...tabProps} />}
          {tab.id === "hex" && <HexMode {...tabProps} />}
          {tab.id === "attestation" && <AttestationMode {...tabProps} />}
        </div>
      ))}
    </section>
  );
}
