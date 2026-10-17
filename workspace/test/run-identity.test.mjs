#!/usr/bin/env node
/**
 * Runner for test/identity_sts.test.ts (no test framework in workspace/ —
 * plain node + tsc, mirroring scripts/e2e-court.mjs). Compiles lib/ + the
 * test to a temp outDir, then imports the compiled test, which exits
 * 0 pass / 1 fail / 3 SKIP (substrate down).
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TSC = path.join(WS_ROOT, 'node_modules', 'typescript', 'bin', 'tsc');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'identity-court-'));
fs.symlinkSync(path.join(WS_ROOT, 'node_modules'), path.join(tmp, 'node_modules'), 'dir');
const tsconfig = {
  compilerOptions: {
    outDir: path.join(tmp, 'js'),
    rootDir: WS_ROOT,
    module: 'commonjs',
    moduleResolution: 'node10',
    ignoreDeprecations: '6.0',
    target: 'es2022',
    esModuleInterop: true,
    skipLibCheck: true,
    lib: ['es2022', 'dom'],
    typeRoots: [path.join(WS_ROOT, 'node_modules', '@types')],
    types: ['node'],
    noEmitOnError: false,
  },
  include: [
    path.join(WS_ROOT, 'lib', 'smalt.ts'),
    path.join(WS_ROOT, 'lib', 'azure', 'identity.ts'),
    path.join(WS_ROOT, 'test', 'identity_sts.test.ts'),
  ],
};
const cfgPath = path.join(tmp, 'tsconfig.identity.json');
fs.writeFileSync(cfgPath, JSON.stringify(tsconfig, null, 2));
const tsc = spawnSync(process.execPath, [TSC, '-p', cfgPath], { encoding: 'utf8' });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc over identity client + test\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
await import(pathToFileURL(path.join(tmp, 'js', 'test', 'identity_sts.test.js')).href);
