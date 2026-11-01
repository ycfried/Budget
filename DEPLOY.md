# Deploying this prototype

This is Milestone A demo code: fake demo data only, no real bank data,
no secrets. Do not commit any real card numbers, tokens, or passwords.

## GitHub Pages (free, static preview)

1. Create an empty repo on GitHub (public, no README/license/.gitignore —
   this folder already has its own files).
2. Push this folder's contents to that repo's main branch.
3. GitHub repo → Settings → Pages → Source: Deploy from a branch,
   Branch: main, Folder: / (root). Save.
4. Your URL will be https://<username>.github.io/<repo>/ — open it in
   Safari on each iPhone → Share → Add to Home Screen.

Note: Pages hosting alone does not sync data between phones. This
prototype stores data in each phone's own browser. A shared household
budget needs a backend/database (see ARCHITECTURE.md) — that is the
next step after the preview works.
