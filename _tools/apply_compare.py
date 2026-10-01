#!/usr/bin/env python3
"""Adds the Compare section to notes.ravindran.in.

Usage: python3 apply_compare.py <path to ravindran-notes-main>
Copies compare/ into the site, adds a Compare menu link (after GCP) on every page,
adds Compare to the home page, switches the header to the phone menu below 920px
so the longer menu fits, notes it in the README, and rebuilds sitemap.xml.
Safe to run more than once.
"""
import os, re, sys, shutil, subprocess

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
here = os.path.dirname(os.path.abspath(__file__))
assert os.path.exists(os.path.join(root, 'gcp', 'index.html')), 'not the site root'

# 1. compare/ folder
dst = os.path.join(root, 'compare')
os.makedirs(dst, exist_ok=True)
for f in os.listdir(os.path.join(here, 'compare')):
    shutil.copy2(os.path.join(here, 'compare', f), os.path.join(dst, f))

# 2. menu link after GCP on every page
pat = re.compile(r'(<li><a href="([^"]*)gcp/index.html"(?: aria-current="page")?>GCP</a></li>)(\s*)')
changed = 0
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if not x.startswith('.')]
    for f in files:
        if not f.endswith('.html'):
            continue
        p = os.path.join(d, f)
        s = open(p, encoding='utf-8').read()
        if 'compare/index.html' in s.split('</nav>')[0]:
            continue
        t = pat.sub(lambda m: m.group(1) + m.group(3) + f'<li><a href="{m.group(2)}compare/index.html">Compare</a></li>' + m.group(3), s, count=1)
        if t != s:
            open(p, 'w', encoding='utf-8').write(t)
            changed += 1
print('menu link added on', changed, 'pages')

# 3. home page: status card and topic row
p = os.path.join(root, 'index.html')
s = open(p, encoding='utf-8').read()
if 'compare/index.html"><span class="tname">' not in s:
    s = s.replace('<li><a href="gcp/index.html">GCP</a><span class="st st-live">10 guides, 8 scripts</span></li>',
                  '<li><a href="gcp/index.html">GCP</a><span class="st st-live">10 guides, 8 scripts</span></li>\n'
                  '        <li><a href="compare/index.html">Compare</a><span class="st st-live">3 comparisons</span></li>', 1)
    m = re.search(r'\s*<li><a class="topic-row" href="gcp/index.html">.*?</li>', s)
    if m:
        s = s.replace(m.group(0), m.group(0) + '\n      <li><a class="topic-row" href="compare/index.html"><span class="tname">Compare</span>'
                      '<span class="tdesc">Google Cloud, AWS and Azure side by side: networking, network protection, WAF and DDoS.</span>'
                      '<span class="st st-live">Live</span></a></li>', 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('home page updated')

# 4. header: phone menu below 920px (was 760px) so nine menu items fit
p = os.path.join(root, 'assets', 'site.css')
s = open(p, encoding='utf-8').read()
old = '@media (max-width: 760px) {\n  .menu-toggle { display: block; }'
if old in s:
    s = s.replace(old, '@media (max-width: 920px) {\n  .menu-toggle { display: block; }', 1)
    s = s.replace('.header-row { display: flex;', '.brand { white-space: nowrap; }\n.header-row { display: flex;', 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('header breakpoint updated')

# 5. README
p = os.path.join(root, 'README.md')
s = open(p, encoding='utf-8').read()
if 'compare/' not in s:
    s = s.replace('├── gcp/', '├── compare/                Google Cloud, AWS and Azure compared (networking, protection, WAF/DDoS)\n├── gcp/', 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('README updated')

# 6. sitemap
subprocess.run([sys.executable, os.path.join(root, '_tools', 'build-sitemap.py')], check=True)
