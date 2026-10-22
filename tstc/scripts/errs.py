import re, sys
# Summarize moon build output: one line per diagnostic (errors first).
text = open(sys.argv[1]).read()
blocks = re.split(r'\n(?=(?:Error|Warning): \[)', text)
errs = []
for b in blocks:
    m = re.match(r'(Error|Warning): \[(\d+)\]', b)
    if not m: continue
    loc = re.search(r'╭─\[ .*/src/main/([^ ]+) \]', b)
    msgs = re.findall(r'╰──+ (.*)', b)
    item = f"{m.group(1)} {loc.group(1) if loc else '?'}: {' | '.join(msgs)[:300]}"
    if m.group(1) == 'Error': errs.append(item)
for e in errs[:int(sys.argv[2]) if len(sys.argv) > 2 else 60]: print(e)
print(f"-- {len(errs)} errors")
other = [l for l in text.split('\n') if 'ld:' in l or 'Undefined' in l or 'error:' in l.lower() and 'Error: [' not in l]
for l in other[:20]: print(l[:300])
