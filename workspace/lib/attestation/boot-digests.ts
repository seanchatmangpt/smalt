/**
 * Known-hardware boot-measurement allowlist.
 *
 * In production this map is provisioned from the OEM manifest (secure
 * element firmware measurements). Entries here are placeholders — the
 * contract is: a receipt whose `bootDigest` does not appear in the
 * allowlist for its `chipsetSerial` is invalid, and a serial with no
 * allowlist entry at all is refused (unrecognized device).
 */

export interface BootDigestEntry {
  /** Expected SHA-256 digest (lowercase hex, 64 chars) of the device boot measurement. */
  digest: string;
  /** Provisioning provenance. */
  source: string;
}

/**
 * chipsetSerial -> allowlisted boot measurement.
 * Placeholder hardware inventory — replace with OEM-provisioned data.
 */
export const KNOWN_BOOT_DIGESTS: ReadonlyMap<string, BootDigestEntry> =
  new Map([
    [
      'SMALT-SE-0000000001',
      {
        digest:
          'aa'.repeat(32),
        source: 'placeholder:replace-with-oem-manifest',
      },
    ],
    [
      'SMALT-SE-0000000002',
      {
        digest: 'bb'.repeat(32),
        source: 'placeholder:replace-with-oem-manifest',
        },
    ],
  ]);

export type BootDigestCheck =
  | { allowed: true }
  | { allowed: false; reason: 'UNKNOWN_DEVICE' | 'DIGEST_MISMATCH' };

/** Pure, total check — never throws. */
export function checkBootDigest(
  chipsetSerial: unknown,
  bootDigest: unknown
): BootDigestCheck {
  if (typeof chipsetSerial !== 'string' || chipsetSerial.length === 0) {
    return { allowed: false, reason: 'UNKNOWN_DEVICE' };
  }
  const entry = KNOWN_BOOT_DIGESTS.get(chipsetSerial);
  if (!entry) return { allowed: false, reason: 'UNKNOWN_DEVICE' };
  if (
    typeof bootDigest !== 'string' ||
    bootDigest.toLowerCase() !== entry.digest
  ) {
    return { allowed: false, reason: 'DIGEST_MISMATCH' };
  }
  return { allowed: true };
}
