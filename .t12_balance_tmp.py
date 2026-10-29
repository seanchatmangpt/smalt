import io
import re

src = io.open('test/integration/chaos_injectors_test.exs', encoding='utf-8').read()

# strip line comments (no heredocs with # in this file) and string bodies crudely
lines = []
for ln in src.split('\n'):
    # naive: drop content after # unless inside a known string-heavy line
    if '#' in ln and not ln.strip().startswith('#'):
        pass  # keep line; '#' inside strings like "AMQP\x00" won't matter for do/end/fn tokens
    lines.append(ln)
body = '\n'.join(lines)

# remove string literals crudely (single and double quoted, non-multiline)
body = re.sub(r'"(?:\\.|[^"\\])*"', '""', body)
body = re.sub(r"'(?:\\.|[^'\\])*'", "''", body)

opens = len(re.findall(r'\bdo\b(?!\s*:)', body)) + len(re.findall(r'\bfn\b', body))
closes = len(re.findall(r'\bend\b', body))
print('block openers (do+fn):', opens)
print('closers (end):', closes)
print('sleep:', re.findall(r'Process\.sleep|timer\.sleep', body))
print('ok-balance:', opens == closes)
