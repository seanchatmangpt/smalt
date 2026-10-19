// assert.ts — typed REST error classifier for the external tier.
export interface RestErrorShape {
  status: number | undefined;
  code: string | undefined;
  name: string;
  message: string;
}

export function classify(err: any): RestErrorShape {
  return {
    status: err?.statusCode ?? err?.response?.status ?? undefined,
    code:
      err?.code ??
      err?.parsedBody?.error?.code ??
      err?.error?.code ??
      err?.details?.error?.code ??
      undefined,
    name: String(err?.name ?? "Error"),
    message: String(err?.message ?? "").slice(0, 240),
  };
}

export function expectRestError(
  fn: () => Promise<unknown>,
  match: { status?: number | number[]; code?: string | RegExp },
  label: string,
): Promise<RestErrorShape> {
  return (async () => {
    let err: any;
    try {
      await fn();
    } catch (e) {
      err = e;
    }
    if (!err) {
      throw new Error(
        `CHECK-FAIL ${label}: expected a typed error ${JSON.stringify(match)} but the call resolved`,
      );
    }
    const got = classify(err);
    if (match.status !== undefined) {
      const want = Array.isArray(match.status) ? match.status : [match.status];
      if (got.status === undefined || !want.includes(got.status)) {
        throw new Error(
          `CHECK-FAIL ${label}: expected status ${want.join("/")} got ${got.status} (${got.name}: ${got.message})`,
        );
      }
    }
    if (match.code !== undefined) {
      const ok =
        typeof match.code === "string"
          ? got.code === match.code
          : match.code instanceof RegExp
            ? match.code.test(got.code ?? "")
            : false;
      if (!ok) {
        throw new Error(
          `CHECK-FAIL ${label}: expected error.code ${String(match.code)} got ${got.code} (${got.name}: ${got.message})`,
        );
      }
    }
    return got;
  })();
}
