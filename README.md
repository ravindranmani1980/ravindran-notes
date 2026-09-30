# notes.ravindran.in

Field notes and PowerShell scripts on cloud and IT operations by [Ravindran Mani](https://ravindran.in). Hands-on AWS examples live separately at [aws.ravindran.in](https://aws.ravindran.in).

The site is plain HTML and CSS. There is no build step: what's in this repository is exactly what GitHub Pages serves.

| Topic | Status |
|---|---|
| SharePoint | Live: 14 guides, 18 scripts (2005–2024) |
| Azure | Live: 10 guides, 8 scripts |
| AWS | Live: 10 guides, 8 scripts |
| Google Cloud (GCP) | Live: 10 guides, 8 scripts |
| FinOps | In progress (not linked yet) |

## Folder structure

```
notes.ravindran.in/
├── index.html              Home page: topics and their status
├── about.html
├── 404.html
├── CNAME                   Custom domain for GitHub Pages (notes.ravindran.in)
├── sitemap.xml             All published pages, for search engines (generated)
├── robots.txt              Points search engines at the sitemap
├── assets/
│   ├── site.css            All styles. Colors are at the top.
│   ├── site.js             Mobile menu, copy buttons, guide contents highlight
│   ├── prism.js            PowerShell syntax highlighting (self-hosted)
│   └── favicon.svg
├── scripts/index.html      Scripts hub: one row per topic with its script count
├── sharepoint/
│   ├── index.html          Topic page: timeline, guides, scripts, test URLs
│   ├── guides/             One page per guide
│   └── scripts/            One page per script, with the .ps1 next to it
├── azure/                  Landing page, guides/, scripts/ and environment/ (same layout as sharepoint/)
├── aws/                    Landing page, guides/, scripts/ and environment/ (same layout as azure/)
├── gcp/                    Landing page, guides/, scripts/ and environment/ (same layout as azure/)
├── finops/                 Starter page + empty guides/ and scripts/
├── _tools/                 build-sitemap.py (not published)
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

**A script:** put the `.ps1` in `<topic>/scripts/`, copy `_templates/script.html` next to it, and fill it in. Add it to `<topic>/scripts/index.html` and update that topic's count on `scripts/index.html`. If it's about cost, also list it in the FinOps section. When you change a script, update both the `.ps1` and the code on its page.

**Taking a topic live (for example AWS):**

1. Add at least two or three guides or scripts.
2. On `aws/index.html`, replace the "Planned" list with the landing layout used by `azure/index.html` and `sharepoint/index.html`, and remove the `noindex` line in the `<head>`.
3. Add the menu link on every page. Each page has a commented-out line ready to use; a find-and-replace across all `.html` files does it in one go.
4. On `index.html`, turn the topic's "In progress" entries into links marked Live.

**Sitemap:** after adding, renaming or removing pages, run `python3 _tools/build-sitemap.py` to rebuild `sitemap.xml`. It skips `404.html`, folders starting with `_`, and any page marked `noindex` (such as FinOps until it goes live).

**Code blocks:** use `<pre><code class="language-powershell">...</code></pre>` and escape `<`, `>` and `&` as `&lt;`, `&gt;` and `&amp;`. Highlighting and the Copy button are added automatically.

## Example naming

Each topic uses fixed example names so readers always know what to replace.

| Topic | Example | Used for |
|---|---|---|
| SharePoint | `https://sharepoint.ravindran.in` | SharePoint Server test farm |
| SharePoint | `https://sharepointonline.ravindran.in` | SharePoint Online test tenant |
| SharePoint | `https://sharepointonline-admin.ravindran.in` | SharePoint Online admin center |
| Azure | `ravindran.onmicrosoft.com`, `sub-notes-test`, `rg-notes-test`, `eastus` | Test tenant, subscription, resource group, region |
| Azure | `vm-notes-test-01`, `rsv-notes-test`, `log-notes-test` | Test VM, Recovery Services vault, Log Analytics workspace |
| Azure | `vnet-notes-test`, `snet-web`, `nsg-notes-test-web`, `asg-web`, `kv-notes-test` | Virtual network, subnet, NSG, application security group, Key Vault |
| AWS | `111122223333` (alias `notes-test`), profile `notes-test`, `us-east-1` | Test account, PowerShell/CLI profile, region |
| AWS | `vpc-notes-test`, `sg-web`, `ec2-notes-test-01`, `bv-notes-test` | VPC, security group, EC2 instance, backup vault |
| AWS | `aws.ravindran.in` | Route 53 hosted zone in examples; also the hands-on examples site |
| GCP | `ravindran.in` org (`123456789012`), `prj-notes-test`, `us-east1` / `us-east1-b` | Organization, test project, region and zone |
| GCP | `vpc-notes-test`, `vm-notes-test-01`, `sa-app@prj-notes-test.iam.gserviceaccount.com` | VPC, VM, service account |
| GCP | `gcp.ravindran.in` | Cloud DNS zone in examples |

## License

MIT. See [LICENSE](LICENSE). Scripts are provided as-is; test in a non-production environment first.
