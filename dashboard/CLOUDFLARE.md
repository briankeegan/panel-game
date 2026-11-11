# The stats page on Cloudflare Pages (https://ranmaru-stats.pages.dev)

The page is built into the `gh-pages` branch as before. When the repository variable `CF_PAGES_PROJECT` is set, every publish
also asks for a copy on Cloudflare Pages (`dashboard/site_git.sh`, `site_copy`), made by the `ranmaru-site` mode of
`bot-prod-smoke-test.yml` on its own runner (the bot's runner only makes one API call). Nothing happens until you set it up.

## One-time setup (about 5 minutes)

1. **Cloudflare account** (free): https://dash.cloudflare.com/sign-up. Note the **Account ID** (right side of the dashboard home page).
2. **API token**: My Profile > API Tokens > Create Token > Create Custom Token. Permission: *Account* > *Cloudflare Pages* > *Edit*.
   Account resources: your account. Copy the token once.
3. **Repository secrets** (repo > Settings > Secrets and variables > Actions > *Secrets*):
   - `CLOUDFLARE_API_TOKEN` = the token
   - `CLOUDFLARE_ACCOUNT_ID` = the account id
4. **Repository variable** (same page > *Variables*): `CF_PAGES_PROJECT` = `ranmaru-stats`
   (the address is `<project>.pages.dev`; if the name is taken, pick another and use it here).
5. **First copy**: Actions > Bot Prod Smoke Test > Run workflow > mode `ranmaru-site`, branch `bramp/multi-player`.
   It creates the project and publishes. After that every publish updates it by itself.

## What is and is not hidden
- The page has no links out and no GitHub names in it, and asks search engines not to list it (`noindex`).
- The old `https://<owner>.github.io/panel-game/` address keeps working until the Pages setting on the repo is turned off
  (repo > Settings > Pages > Unpublish site). Do that once you have moved.
- The commit hash of each version is shown as plain text.
