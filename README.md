# notes.ravindran.in

Field notes and PowerShell scripts on cloud and IT operations by [Ravindran Mani](https://ravindran.in).

The site is plain HTML and CSS. There is no build step: what's in this repository is exactly what GitHub Pages serves.

| Topic | Status |
|---|---|
| SharePoint | Live: 14 guides, 18 scripts (2005–2024) |
| Azure | In progress (not linked yet) |
| AWS | In progress (not linked yet) |
| FinOps | In progress (not linked yet) |

## Folder structure

```
notes.ravindran.in/
├── index.html              Home page: topics and their status
├── about.html
├── 404.html
├── CNAME                   Custom domain for GitHub Pages (notes.ravindran.in)
├── assets/
│   ├── site.css            All styles. Colors are at the top.
│   ├── site.js             Mobile menu, copy buttons, guide contents highlight
│   ├── prism.js            PowerShell syntax highlighting (self-hosted)
│   └── favicon.svg
├── scripts/index.html      Every script on the site, by topic
├── sharepoint/
│   ├── index.html          Topic page: timeline, guides, scripts, test URLs
│   ├── guides/             One page per guide
│   └── scripts/            One page per script, with the .ps1 next to it
├── azure/                  Starter page + empty guides/ and scripts/
├── aws/                    Starter page + empty guides/ and scripts/
├── finops/                 Starter page + empty guides/ and scripts/
└── _templates/             Page templates to copy (not published: GitHub
                            Pages skips folders starting with _)
```

## Publish on GitHub Pages with notes.ravindran.in

1. Create a repository on GitHub (for example `notes`) and upload the contents of this folder to it, including the `CNAME` file.
   With Git:

   ```bash
   git init
   git add .
   git commit -m "notes.ravindran.in"
   git branch -M main
   git remote add origin https://github.com/<your-user>/notes.git
   git push -u origin main
   ```

2. In the repository, go to **Settings > Pages**. Under **Build and deployment**, set **Source** to **Deploy from a branch**, choose **main** and **/ (root)**, and save.
3. At your DNS provider for ravindran.in, add a record:

   | Type | Name | Value |
   |---|---|---|
   | CNAME | `notes` | `<your-user>.github.io` |

4. Back in **Settings > Pages**, confirm the custom domain shows `notes.ravindran.in`. Once the DNS check passes, tick **Enforce HTTPS** (the certificate can take up to an hour).

Every push to `main` updates the site within a minute or two.

## Preview locally

Open `index.html` in a browser. All links are relative, so the site works straight from the folder. (The 404 page is the only one that needs the real domain.)

## Adding content

**A guide:** copy `_templates/guide.html` to `<topic>/guides/<name>.html`, fill it in, then add it to the guide list on `<topic>/index.html` and update the previous/next links on its neighbours.

**A script:** put the `.ps1` in `<topic>/scripts/`, copy `_templates/script.html` next to it, and fill it in. Add it to `<topic>/index.html` and to `scripts/index.html`. If it's about cost, also list it in the FinOps section. When you change a script, update both the `.ps1` and the code on its page.

**Taking a topic live (for example Azure):**

1. Add at least two or three guides or scripts.
2. On `azure/index.html`, replace the "Planned" list with guide and script lists (copy the layout from `sharepoint/index.html`), and remove the `noindex` line in the `<head>`.
3. Add the menu link on every page. Each page has a commented-out line ready to use; a find-and-replace across all `.html` files does it in one go.
4. On `index.html`, turn the topic's "In progress" entries into links marked Live.

**Code blocks:** use `<pre><code class="language-powershell">...</code></pre>` and escape `<`, `>` and `&` as `&lt;`, `&gt;` and `&amp;`. Highlighting and the Copy button are added automatically.

## Example naming

Each topic uses fixed example names so readers always know what to replace.

| Topic | Example | Used for |
|---|---|---|
| SharePoint | `https://sharepoint.ravindran.in` | SharePoint Server test farm |
| SharePoint | `https://sharepointonline.ravindran.in` | SharePoint Online test tenant |
| SharePoint | `https://sharepointonline-admin.ravindran.in` | SharePoint Online admin center |
| Azure (suggested) | `sub-notes-test`, `rg-notes-test` | Test subscription and resource group |
| AWS (suggested) | `notes-test` account alias, `us-east-1` | Test account and default region |

## License

MIT. See [LICENSE](LICENSE). Scripts are provided as-is; test in a non-production environment first.
