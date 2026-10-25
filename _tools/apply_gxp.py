#!/usr/bin/env python3
"""Takes the GxP section live in notes.ravindran.in (run from anywhere; idempotent).

Assumes gxp/ is already in the site folder. It:
  - adds a GxP menu link after FinOps on every page (including _templates and 404.html)
  - moves the phone-menu breakpoint from 920px to 1080px (ten menu items need the room)
  - adds GxP to the home page status card, topic list and hero text
  - adds a GxP row to the scripts hub and updates the total
  - adds a sentence to about.html and rows to README.md
  - rebuilds sitemap.xml
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
changed = []

def rw(rel, fn):
    p = os.path.join(ROOT, rel)
    s = open(p, encoding='utf-8').read()
    t = fn(s)
    if t != s:
        open(p, 'w', encoding='utf-8', newline='').write(t)
        changed.append(rel)

def must(s, old):
    if old not in s:
        sys.exit(f'Expected text not found, stopping: {old[:80]}')
    return old

if not os.path.isfile(os.path.join(ROOT, 'gxp', 'index.html')):
    sys.exit('gxp/index.html not found. Copy the gxp folder into the site first.')

# 1. Menu link
fin = re.compile(r'^([ \t]*)<li><a href="((?:\.\./)*)finops/index\.html"( aria-current="page")?>FinOps</a></li>(\r?\n)', re.M)
def nav(s):
    if re.search(r'<li><a href="(?:\.\./)*gxp/index\.html"', s):
        return s
    t = fin.sub(lambda m: m.group(0) + f'{m.group(1)}<li><a href="{m.group(2)}gxp/index.html">GxP</a></li>{m.group(4)}', s, count=1)
    if t != s:
        return t
    # one-line menus (sharepoint lists) and absolute links (404.html)
    inline = re.compile(r'<li><a href="((?:\.\./)*|/)finops/index\.html"( aria-current="page")?>FinOps</a></li>')
    return inline.sub(lambda m: m.group(0) + f'<li><a href="{m.group(1)}gxp/index.html">GxP</a></li>', s, count=1)

for d, dirs, files in os.walk(ROOT):
    dirs[:] = sorted(x for x in dirs if not x.startswith('.') and x not in ('dist', 'node_modules'))
    rel_d = os.path.relpath(d, ROOT)
    if rel_d.split(os.sep)[0] == 'gxp':
        continue
    for f in sorted(files):
        if f.endswith('.html'):
            rw(os.path.normpath(os.path.join(rel_d, f)), nav)

# 2. Phone-menu breakpoint
rw('assets/site.css', lambda s: s.replace('@media (max-width: 920px)', '@media (max-width: 1080px)'))

# 3. Home page
def home(s):
    if 'href="gxp/index.html">GxP</a><span class="st' in s:
        return s
    card = must(s, '<li><a href="finops/index.html">FinOps</a><span class="st st-live">7 guides, 12 scripts</span></li>')
    s = s.replace(card, card + '\n        <li><a href="gxp/index.html">GxP</a><span class="st st-live">10 guides, 7 scripts</span></li>')
    i = s.index('<li><a class="topic-row" href="finops/index.html">')
    j = s.index('</li>', i) + len('</li>')
    s = s[:j] + ('\n      <li><a class="topic-row" href="gxp/index.html"><span class="tname">GxP</span><span class="tdesc">'
                 'Regulated systems on Azure, AWS and SharePoint: Part 11 and Annex 11 for IT, validation, audit trails, '
                 'access control, change control, backup and disaster recovery, with evidence scripts.</span>'
                 '<span class="st st-live">Live</span></a></li>') + s[j:]
    s = s.replace('SharePoint, Azure, AWS, Google Cloud and cloud cost management.',
                  'SharePoint, Azure, AWS, Google Cloud, cloud cost management and GxP compliance.')
    s = re.sub(r'(<meta name="description" content="[^"]*?) and FinOps( by Ravindran Mani\.")', r'\1, FinOps and GxP\2', s)
    return s
rw('index.html', home)

# 4. Scripts hub
def hub(s):
    if 'href="../gxp/scripts/index.html"' in s:
        return s
    i = s.index('<li><a class="topic-row" href="../finops/scripts/index.html">')
    j = s.index('</li>', i) + len('</li>')
    s = s[:j] + ('<li><a class="topic-row" href="../gxp/scripts/index.html"><span class="tname">GxP</span><span class="tdesc">'
                 'Read-only evidence for regulated systems: Azure access reviews, audit log coverage and backup evidence, '
                 'AWS audit trail, Part 11 conformance pack and restore evidence, and SharePoint library controls.</span>'
                 '<span class="st st-live">7 scripts</span></a></li>') + s[j:]
    return re.sub(r'(\d+) scripts in all\.', lambda m: f'{int(m.group(1)) + 7} scripts in all.', s, count=1)
rw('scripts/index.html', hub)

# 5. About
rw('about.html', lambda s: s if 'GxP notes' in s else s.replace(
    must(s, 'FinOps notes are being added.'),
    'The FinOps notes cover cost across all three clouds, and the GxP notes cover running regulated systems on them: '
    'Part 11 and Annex 11, validation, audit trails, access control, change control, and backup and disaster recovery.'))

# 6. README
def readme(s):
    if '| GxP |' in s:
        return s
    row = must(s, '| FinOps | Live: 7 cross-cloud guides; links 12 cost scripts from the cloud sections |')
    s = s.replace(row, row + '\n| GxP | Live: 10 guides, 7 read-only evidence scripts |')
    tree = re.search(r'^├── finops/.*$', s, re.M)
    if tree:
        col = re.match(r'├── finops/\s*', tree.group(0)).end()
        s = s[:tree.end()] + '\n' + '├── gxp/'.ljust(col) + 'GxP for IT: guides/, evidence scripts/ and environment/ (same layout as azure/)' + s[tree.end():]
    gcp = re.search(r'^\| GCP \| `gcp\.ravindran\.in` .*$', s, re.M)
    if gcp:
        s = s[:gcp.end()] + (
            '\n| GxP | tags `GxP = Yes`, `GxPSystemId = CSV-0042`; `sub-notes-gxp-prod`, `rg-notes-lims` | GxP scope marker, example system, Azure subscription and resource group |'
            '\n| GxP | `777788889999` (alias `notes-gxp`), `bv-notes-gxp`, `https://sharepointonline.ravindran.in/sites/qms` | AWS GxP account, backup vault, controlled documents site |') + s[gcp.end():]
    return s
rw('README.md', readme)

# 7. Sitemap
out = subprocess.run([sys.executable, os.path.join(ROOT, '_tools', 'build-sitemap.py')], capture_output=True, text=True)
print(out.stdout.strip() or out.stderr.strip())
print(f'{len(changed)} files changed')
for c in changed[:8]:
    print('  ' + c)
if len(changed) > 8:
    print(f'  ... and {len(changed) - 8} more')
