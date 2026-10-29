/**
 * BK-118 / RU-3 adoption #1 — pattern-port of react-use's `useAsyncFn`
 * (streamich/react-use v17.6.1, Unlicense), per RU-4 Option C: in-flight
 * standing lives in a mutable core (the ref discipline) that reads fresh on
 * every call, `error` is captured from throws, and no npm dep is added.
 *
 * The ref-semantics live in the framework-free `createAsyncFnCore` so the
 * node court exercises them without React; `useAsyncFn` is the thin React
 * wrapper (stable `fn`, state snapshot re-renders on transitions).
 */

import { useCallback, useState } from "react";

/** Snapshot state, mirroring vendor's { loading, error }. */
export interface AsyncFnState {
  loading: boolean;
  error: unknown;
}

/** Framework-free core: one per logical action (admit, sync). */
export interface AsyncFnCore {
  /** Fresh at any moment — the ref discipline, never a stale closure. */
  readonly loading: boolean;
  /** Captured error from the last rejected run, else undefined. */
  readonly error: unknown;
  /** Run `task`, tracking in-flight/error. Never gates, never drops. */
  run: <T>(task: () => Promise<T>) => Promise<T | undefined>;
}

/** Mint a fresh in-flight core. */
export function createAsyncFnCore(): AsyncFnCore {
  let inFlight = false;
  let error: unknown = undefined;

  return {
    get loading() {
      return inFlight;
    },
    get error() {
      return error;
    },
    run<T>(task: () => Promise<T>): Promise<T | undefined> {
      inFlight = true;
      error = undefined;
      return task()
        .then((value: T) => {
          inFlight = false;
          return value;
        })
        .catch((err: unknown) => {
          inFlight = false;
          error = err;
          return undefined; // errors surface as state, never rethrown
        });
    },
  };
}

/** React wrapper result: state snapshot for render, core for fresh callback reads. */
export type UseAsyncFn = [
  AsyncFnState,
  <T>(task: () => Promise<T>) => Promise<T | undefined>,
  AsyncFnCore,
];

/** React wrapper: stable fn identity, state snapshot re-renders on transitions. */
export function useAsyncFn(): UseAsyncFn {
  // useState initializer (not a ref read): the core is mutable and stable,
  // and reading it during render is not a ref access.
  const [core] = useState(createAsyncFnCore);
  const [state, setState] = useState<AsyncFnState>({ loading: false, error: undefined });

  const fn = useCallback(
    <T,>(task: () => Promise<T>): Promise<T | undefined> => {
      setState({ loading: true, error: undefined });
      return core.run(task).then((value) => {
        // settle: mirror the core's post-run standing into render state
        setState({ loading: core.loading, error: core.error });
        return value;
      });
    },
    [core],
  );

  return [state, fn, core];
}
