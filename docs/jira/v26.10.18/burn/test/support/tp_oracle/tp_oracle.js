// JCS oracle: sorted keys (UTF-16 code unit order = JS default sort),
// ECMAScript number formatting (JSON.stringify). Reads JSONL on stdin,
// emits canonical JSONL on stdout.
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n');
for (const line of lines) {
  if (!line.trim()) continue;
  console.log(canon(JSON.parse(line)));
}
function canon(v) {
  if (v === null || typeof v === 'boolean') return JSON.stringify(v);
  if (typeof v === 'number') return JSON.stringify(v);
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  const keys = Object.keys(v).sort();
  return '{' + keys.map(k => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
}
