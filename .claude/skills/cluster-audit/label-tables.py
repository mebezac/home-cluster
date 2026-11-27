"""Add data-label (from the table's <th>) and a 'lead' class on the first two cells of every row,
so the phone layout can show each row as a labelled card. Idempotent."""
import re, sys
p = sys.argv[1]
s = open(p).read()
def do_table(m):
    t = m.group(0)
    heads = [re.sub('<[^>]+>', '', h).strip() for h in re.findall(r'<th[^>]*>(.*?)</th>', t)]
    def do_row(rm):
        row = rm.group(0)
        if '<th' in row: return row
        cells = list(re.finditer(r'<td([^>]*)>', row))
        out, last, col = [], 0, 0
        for i, c in enumerate(cells):
            attrs = c.group(1)
            span = int(re.search(r'colspan="(\d+)"', attrs).group(1)) if 'colspan' in attrs else 1
            label = 'Usage' if span > 1 else (heads[col] if col < len(heads) else '')
            attrs = re.sub(r'\s*data-label="[^"]*"', '', attrs)
            if i < 2:
                if 'class="' in attrs:
                    if 'lead' not in attrs: attrs = attrs.replace('class="', 'class="lead ', 1)
                else: attrs += ' class="lead"'
            attrs += f' data-label="{label}"'
            out.append(row[last:c.start()] + f'<td{attrs}>'); last = c.end(); col += span
        out.append(row[last:])
        return ''.join(out)
    return re.sub(r'<tr[^>]*>.*?</tr>', do_row, t, flags=re.S)
s = re.sub(r'<table>.*?</table>', do_table, s, flags=re.S)
open(p, 'w').write(s)
