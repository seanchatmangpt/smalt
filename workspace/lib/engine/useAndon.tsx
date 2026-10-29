"use client";

/**
 * Pattern 14 — Ambient Cord.
 *
 * ANDON is ambient page state: one provider owns the raised/refused
 * standing, any consumer can pull the cord, and the banner renders from
 * state with the contract selectors (`[role="alert"]`, `data-andon-state`,
 * `data-andon-rule`, `data-action="acknowledge-andon"`). No prop drilling;
 * the terminal hook raises through context.
 */

import { createContext, useCallback, useContext, useMemo, useState } from "react";

export interface AndonState {
  /** True while a refusal stands — the cord is pulled. */
  raised: boolean;
  /** Structured refusal rule (e.g. ALLOC_CAP_EXCEEDED) when raised. */
  rule: string;
}

export interface AndonApi extends AndonState {
  /** Pull the cord with a structured rule. */
  raise: (rule: string) => void;
  /** Acknowledge — the banner clears, the rule is remembered as lastRule. */
  acknowledge: () => void;
  /** Last raised rule (persists after acknowledge; "" before the first). */
  lastRule: string;
}

const AndonContext = createContext<AndonApi | null>(null);

export function AndonProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<AndonState & { lastRule: string }>({
    raised: false,
    rule: "",
    lastRule: "",
  });

  const raise = useCallback((rule: string) => {
    setState({ raised: true, rule, lastRule: rule });
  }, []);

  const acknowledge = useCallback(() => {
    setState((s) => ({ ...s, raised: false, rule: "" }));
  }, []);

  const api = useMemo<AndonApi>(
    () => ({ ...state, raise, acknowledge }),
    [state, raise, acknowledge],
  );

  return (
    <AndonContext.Provider value={api}>
      {state.raised && (
        <div
          role="alert"
          data-andon-state="RAISED"
          data-andon-rule={state.rule}
          data-action="acknowledge-andon"
          onClick={acknowledge}
          style={{
            background: "#fee2e2",
            border: "2px solid #b91c1c",
            color: "#7f1d1d",
            padding: 12,
            marginBottom: 12,
            cursor: "pointer",
          }}
        >
          ANDON — refusal at byte 0. Frame NOT journaled. rule={state.rule} (click to
          acknowledge)
        </div>
      )}
      {children}
    </AndonContext.Provider>
  );
}

/** Read the andon standing; raises from any consumer via the returned api. */
export function useAndon(): AndonApi {
  const ctx = useContext(AndonContext);
  if (!ctx) {
    throw new Error("useAndon outside AndonProvider — mount the Ambient Cord first");
  }
  return ctx;
}
