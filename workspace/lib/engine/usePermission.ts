"use client";

/**
 * BK-130 / RU-3 adoption #5 — pattern-port of react-use's `usePermission`
 * (streamich/react-use v17.6.1, Unlicense), per RU-4 Option C: no npm dep,
 * prior-art disclosure in header, domain-blind, SSR-safe (never touches
 * `navigator.permissions` at render; server state is "prompt"-class
 * `unknown` until mounted).
 *
 * Wiring (RU-3 item 5): WebAuthn/WebCrypto pre-flight — query the
 * permission standing (`publickey-credential-get` and friends) BEFORE the
 * page wires token issuance, so a denied permission renders a typed
 * refusal instead of a raw challenge failure.
 *
 * The classification lives in the framework-free `permissionClass` so the
 * node court drives it with fake PermissionStatus objects, deterministically.
 */

import { useEffect, useState } from "react";

export type PermissionDescriptorName =
  | "publickey-credential-get"
  | "publickey-credential-create"
  | "crypto"
  | string;

/** Typed standing — the two vendor-extras (`unsupported`, `unknown`) are disclosed, never collapsed. */
export type PermissionClass =
  | "granted"
  | "denied"
  | "prompt"
  | "unsupported"
  | "unknown";

/** Typed refusal for the pre-flight surface (RU-3 item 5). */
export interface PermissionRefusal {
  code: "PERMISSION_REFUSED";
  name: PermissionDescriptorName;
  state: PermissionClass;
  detail: string;
}

/** Pure: classify a raw permission state string (vendor parity + extras). */
export function permissionClass(state: string | undefined | null): PermissionClass {
  switch (state) {
    case "granted":
    case "denied":
    case "prompt":
      return state;
    case undefined:
    case null:
      return "unknown";
    default:
      // known-API-absent case surfaces as unsupported (never a fake granted)
      return "unsupported";
  }
}

/**
 * Pure: the pre-flight verdict. granted → run; anything else → typed
 * refusal with the exact standing attached.
 */
export function preflightPermission(
  name: PermissionDescriptorName,
  state: PermissionClass,
): { ok: true } | { ok: false; refusal: PermissionRefusal } {
  if (state === "granted") return { ok: true };
  return {
    ok: false,
    refusal: {
      code: "PERMISSION_REFUSED",
      name,
      state,
      detail: `pre-flight: permission ${name} is "${state}", refusing before challenge`,
    },
  };
}

/** React hook: reactive Permissions API query with change watching. */
export function usePermission(name: PermissionDescriptorName): PermissionClass {
  const [cls, setCls] = useState<PermissionClass>("unknown");

  useEffect(() => {
    if (typeof navigator === "undefined" || !navigator.permissions?.query) {
      // deferred: not a synchronous setState in the effect body
      queueMicrotask(() => setCls("unsupported"));
      return;
    }
    let status: PermissionStatus | undefined;
    let cancelled = false;
    navigator.permissions
      .query({ name } as unknown as PermissionDescriptor)
      .then((s) => {
        if (cancelled) return;
        status = s;
        setCls(permissionClass(s.state));
        status.onchange = () => setCls(permissionClass(status!.state));
      })
      .catch(() => {
        if (!cancelled) setCls("unsupported");
      });
    return () => {
      cancelled = true;
      if (status) status.onchange = null;
    };
  }, [name]);

  return cls;
}
