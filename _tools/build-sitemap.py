#!/usr/bin/env python3
"""Builds sitemap.xml for notes.ravindran.in.

Run from anywhere:  python3 _tools/build-sitemap.py
Includes every .html page except folders starting with "_" (not published by GitHub Pages),
404.html, and pages marked <meta name="robots" content="noindex">.
index.html pages are listed by their folder URL (https://notes.ravindran.in/azure/).
lastmod is the file's modification date.
"""
import os, re, datetime
from xml.sax.saxutils import escape

SITE = 'https://notes.ravindran.in'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def priority(rel):
    if rel == 'index.html': return '1.0'
    if rel.count('/') == 1 and rel.endswith('index.html'): return '0.9'   # topic landing pages
    if rel.endswith('index.html'): return '0.8'                          # guide, script and environment lists
    if '/guides/' in rel: return '0.7'
    return '0.6'

entries = []
for d, dirs, files in os.walk(ROOT):
    dirs[:] = sorted(x for x in dirs if not x.startswith(('_', '.')))
    for f in sorted(files):
        if not f.endswith('.html'): continue
        path = os.path.join(d, f)
        rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
        if rel == '404.html': continue
        if re.search(r'<meta\s+name="robots"\s+content="[^"]*noindex', open(path, encoding='utf-8').read(), re.I): continue
        url = SITE + '/' + (rel[:-len('index.html')] if rel.endswith('index.html') else rel)
        lastmod = datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
        entries.append((url, lastmod, priority(rel)))

entries.sort(key=lambda e: (e[0].count('/'), e[0]))
lines = ['<?xml version="1.0" encoding="UTF-8"?>',
         '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
for url, lastmod, pri in entries:
    lines.append(f'  <url>\n    <loc>{escape(url)}</loc>\n    <lastmod>{lastmod}</lastmod>\n    <priority>{pri}</priority>\n  </url>')
lines.append('</urlset>')
with open(os.path.join(ROOT, 'sitemap.xml'), 'w', encoding='utf-8', newline='\n') as fh:
    fh.write('\n'.join(lines) + '\n')
print(f'sitemap.xml: {len(entries)} URLs')
