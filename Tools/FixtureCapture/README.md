# FixtureCapture

`fixture-capture` saves real E-Hentai and ExHentai pages and API answers as parser fixtures for ErosKit. It
captures with your own account, removes credentials and personal data from every response, and refuses to write
anything that still fails the fixture hygiene checks (`EHFixtures.FixtureHygiene`).

## Usage

Run from the repository root:

```bash
# Print the plan: sends nothing and checks no credentials.
swift run --package-path Tools/FixtureCapture fixture-capture capture --dry-run

# Capture one site at a time, credentials injected by 1Password.
op run --env-file=Tools/FixtureCapture/capture.env -- \
    swift run --package-path Tools/FixtureCapture fixture-capture capture --sites eh
op run --env-file=Tools/FixtureCapture/capture.env -- \
    swift run --package-path Tools/FixtureCapture fixture-capture capture --sites ex
```

After the sanitizing rules get stricter, fix the fixtures already written offline instead of capturing again:

```bash
# Sends nothing. Sanitizes the captured fixtures (manifest.json), the local-only ones (local/manifest.local.json)
# and, with --constructed, the constructed ones again with the current rules, and rewrites only those that change.
swift run --package-path Tools/FixtureCapture fixture-capture resanitize
swift run --package-path Tools/FixtureCapture fixture-capture resanitize --constructed
```

`resanitize` uses the same sanitizer and checks as a capture: the secrets file, values discovered in the fixtures
themselves, and the credential variables when they are set (run it under `op run` to include them; it works without). Run under `op run` it also adds the username and member id to the secrets file.
Before writing, every fixture and both manifests must pass the checks `FixtureWriter` applies, and the captured public
fixtures the own-content check (`ownupload` and the rules after it, below); otherwise nothing is written and the
findings are listed (paths, lines and rules only). It prints `Changed <path>` for each file it
rewrites. Manifest entries keep every field, `capturedAt` included; a manifest is only rewritten when an entry's URL or
`Location` changes. Running it again changes nothing, since masked text stays masked. Options: `--output DIR` and
`--secrets-file PATH`, as for `capture`; `--constructed` to include `constructed/`. `--constructed` honors
`FixtureHygiene.constructedExemptions` (for example the tag colors of `constructed/eh/account-mytags.html` stay) and
never discovers secrets in constructed fixtures: they hold made-up values, so a "nickname" found in one is fake. They
are still rewritten with the secrets found elsewhere, and the secrets file only changes for new finds in captured and
private fixtures. A list page that still says
"Filtered N galleries" cannot be fixed this way: capture it again (see "Lists with filters disabled").

Capturing `--sites eh` and then `--sites ex` is recommended over one run of both: a run that stops writes nothing,
so a problem on ExHentai would otherwise throw away the E-Hentai requests already made. Each run replaces only the
fixtures of its own sites, so the result is the same.

```
fixture-capture capture [--sites eh,ex] [--targets PATH] [--output DIR] [--secrets-file PATH] [--dry-run]
fixture-capture resanitize [--output DIR] [--secrets-file PATH] [--constructed]
```

| Option | Default | Meaning |
|---|---|---|
| `--sites` | `eh,ex` | Sites to capture, in this order. |
| `--targets` | `Tools/FixtureCapture/targets.json` | Gallery, search terms and so on for each site. |
| `--output` | `Packages/ErosKit/Tests/Fixtures` | Fixture root holding `manifest.json`; must exist. |
| `--secrets-file` | `.fixture-secrets.local` | Local secrets file: read for extra values to remove, then updated with the values discovered in this run and, when set, the username (`EH_USERNAME`) and member id (`EH_IPB_MEMBER_ID`), so offline scans and imports work without `op run`. Login tokens are never stored. Git-ignored, mode 0600. |
| `--dry-run` | | Print `Plan: …`, one `<METHOD> <URL template> -> <fixture path or (not saved)>` line per step, and the names of the capture variables that are set. Values extracted at run time appear as placeholders such as `{gid}`; the image search shows `POST {imageLookupURL|<endpoint>}`, the front page's form action, else the site's endpoint (see below). A part in square brackets is optional: it is sent only when the run needs it. The archiver popup shows `GET …/archiver.php?gid={gid}&token={token}[&or={or}]`: `&or=` is added only when the detail page's archiver link has an `or` parameter, which the site no longer sends (seen in the M0 run). The front page's next page shows `GET {nextPage}[&f_sft=on&f_sfu=on&f_sfl=on]`: of these, only the parameters the link lacks are added (see "Lists with filters disabled"). |

Paths are relative to the current directory. A run replaces the captured fixtures of the selected sites and keeps
constructed fixtures and the other site's fixtures. Steps whose inputs are missing (for example
`contentWarningGallery` is null) are skipped and listed; the run still succeeds.

Before the first real run, replace the placeholders in `targets.json`: `gallery` must be a real gallery URL on the
site's own host (`https://e-hentai.org/g/<gid>/<token>/`, `https://exhentai.org/g/<gid>/<token>/`).
`contentWarningGallery` is optional. `targets.json` is checked in, so put only public pages and search terms in it.

## Page structure under another user agent (`probe-structure`)

The app asks the site with the device's WebKit user agent, while the M0 samples were captured with a Chrome desktop
one. `probe-structure` checks whether the site sends the same page structure to the WebKit one. Run from the
repository root, one site per run (`EH_SP` selects the configuration of one site only):

```bash
op run --env-file=Tools/FixtureCapture/capture.env -- \
    swift run --package-path Tools/FixtureCapture fixture-capture probe-structure --site eh --user-agent '<UA>'
```

- 3 requests per site, strictly one at a time and through the rate limiter: the front page with the Disable Filters
  parameters, the first gallery found on it, that gallery's first image page. GET only, no body, no `inline_set`.
- Sends the given user agent and the cookies of `capture` except `cf_clearance` and `cf_duid` (bound to another user
  agent), so `EH_USER_AGENT` is not needed. Writes nothing.
- Each page is compared with the M0 sample (`{site}/list/front.html`, `{site}/gallery/detail.html`,
  `{site}/image/page.html`) by the presence of structure markers (selector names, see
  `EHParsing.StructureSignature.markers`), plus the row count and display mode of the list. Output is one line per
  page, `<site> <kind> status=<code> same` or `… differs: <name,…>`; selector names and statuses only, no page text.
- Some markers depend on the gallery the walk happens to pick, not on the user agent: `#cdiv > div.c1` (comments),
  `#taglist tr` (tags), `a[href*="/fullimg/"]` (original image), `#favoritelink`, `#loadfail` may be present or
  absent from gallery to gallery. A single `differs` on one of these: check the gallery itself first; do not take
  it as a layout change.
- Each page's line is printed as soon as it is compared, so a stop keeps the lines already printed.
- A 429, 509, 5xx or a ban notice stops the run at once and nothing is retried; wait at least one hour and ask the
  user before running again. The view must be Compact: set `EH_SP` to the same Eros-FE profile number as for M0.
- Result of the first run (2026-11-05, iPhone WebKit user agent, both sites): only `meta[name=viewport]` differs, present in
  the WebKit pages and absent from the M0 samples; treated as the same (see `docs/notes/webkit-ua-structure.md`). It is
  a known difference.
- Future recaptures: set `EH_USER_AGENT` to the WebKit user agent the app's debug page shows (so the samples match
  what the app receives) and record the user agent used in the capture record. `capture`'s default (Chrome) is
  unchanged for now; at the next recapture, make `capture` exit 2 without `EH_USER_AGENT` and drop the default.
- Exit status: 0 all the same, 4 some differ, 1 stopped, 2 bad arguments or credentials.

## Site profile cookie (`probe-sp`)

`probe-sp` checks how the site treats the `sp` cookie, which selects the site profile a request gets: which profile
`uconfig.php` shows as selected with and without it, and whether the answer sets cookies (an `sp` among them). It is
written for the account plan (A5). **A real run needs the user's consent first (account plan A5)**; the automated
tests only use a stub transport. Run from the repository root, one site per run, with `EH_SP` unset:

```bash
op run --env-file=Tools/FixtureCapture/capture.env -- \
    env -u EH_SP swift run --package-path Tools/FixtureCapture fixture-capture probe-sp --site eh --sp 2,4
```

- Read-only: every request is a GET of `https://<site host>/uconfig.php` with no body and no `inline_set`; no form is
  posted, so no setting or profile changes. Every request passes the read-only check before the first one is sent.
  Writes nothing, neither fixtures nor the secrets file.
- At most 4 requests per site: one without `sp`, then one per number given to `--sp` (1 to 3 positive numbers,
  comma-separated, each once). Redirects are not followed, so that is at most 4 HTTP requests too. Strictly one at a
  time and through the rate limiter, as `capture`.
- Headers as `capture` except `cf_clearance` and `cf_duid`: the user agent (`EH_USER_AGENT` or the default),
  `Accept`, `Accept-Language`, `nw=1` and the other credential cookies of the environment. The two Cloudflare cookies
  are left out, as in `probe-structure`: they belong to the browser that earned them, and `sp` does not depend on
  them; so `EH_CF_CLEARANCE` and `EH_CF_DUID` are ignored and need no `EH_USER_AGENT`. The k-th request after the
  first adds `sp=<k-th number>`. `EH_SP` is never sent: the probe chooses the `sp` of each request itself, so with
  `EH_SP` set it exits 2 before sending anything (hence `env -u EH_SP` above).
- Output: one line per request, printed as soon as it is read, so a stop keeps the lines already printed:
  `sp=<n|none> status=<code> selected=<n|none> set-cookie=<name,…|none> set-sp=<n|none>`: the `sp` sent, the
  status, the selected option of the page's profile selector (`select[name=profile_set]`), the names of the cookies
  `Set-Cookie` sets and the value of a `Set-Cookie` `sp` (a profile number; `none` when it is missing, deleted or not
  a number). Numbers, statuses and cookie names only: no cookie value, profile name or page text.
- A 3xx answer is reported as such a line (`status=30x selected=none`, with its `Set-Cookie` names and `sp`) and not
  followed; the probe goes on with the next number. The `Location` is not printed (it may carry a query).
- A 429, 509, 5xx or a ban notice stops the run at once and nothing is retried; wait at least one hour and ask the
  user before running again. On ExHentai an empty or non-HTML answer other than a 3xx stops it as well (the cookies
  are not accepted), and so does any status other than 200 and 3xx.
- Exit status: 0 every request answered with 200 or a 3xx; 1 stopped or a request failed; 2 bad arguments, missing
  or invalid credentials, `EH_SP` set, or more than 3 numbers (nothing was sent).

## Before you capture

- The site's front page must use the **Compact** display mode. The tool checks this first and stops otherwise; it
  never changes site settings. Switch it yourself on the site, or set `EH_SP` to the number of a site profile that
  uses Compact.

## Lists with filters disabled

The user decided on 2026-11-05 that list pages are captured with the account's filters disabled. A list leaves out
the galleries the account's My Tags hide; requesting the same range without filters would show which ones are
missing and so which tags the account hides, and masking the count in "Filtered N galleries from this page" does not
prevent that. So the list steps that showed that line in the M0 run (on both sites: the front page and its next page,
seek, category, both searches, popular, tag and uploader) carry the query parameters of the page's own "Disable
Filters" link, `f_sft=on&f_sfu=on&f_sfl=on`. On the next page link taken from the front page, each is set once:
added when missing, set to `on` when present, repeats (also under a name PHP reads as the same, such as `f.sfu`)
dropped. These are parameters of that request only; no site setting changes, and the read-only check passes them like
any GET. The empty search, the favorites and watched lists, the toplists and the image search result showed no such
line and are requested as before. Any page that still shows it is refused by the hygiene check `filteredlist`, so
nothing is written.

## Kept local-only: personal preference pages

The user decided on 2026-11-04 that personal preference pages are not committed: on each site `account/mytags.html`,
`list/favorites.html`, `list/favorites-cat0.html`, `list/favorites-search.html` and `list/watched.html`
(`PrivateFixtures.paths`). They are captured, sanitized and checked like every other page, and secrets found on them
still mask the other pages, but they are written under the git-ignored `local/` directory of the fixture root
(`Packages/ErosKit/Tests/Fixtures/local/eh/list/favorites.html`, …) and listed in `local/manifest.local.json` (same
format as `manifest.json`), never in `manifest.json`. The dry run shows them as `local/…`, and a run prints how many it
kept local-only. Copies at their old checked-in paths, from runs before this change, must not exist: the writer
deletes any it finds, on either site, drops their `manifest.json` entries and prints `Removed <path>` for each.
Later milestones use these pages locally as a reference for constructed fixtures that can be committed.

## Not captured, imported: the forum profile page

The plan does not capture the forum profile page (`https://forums.e-hentai.org/index.php?showuser=<member id>`). In
the M0 run it answered HTTP 403 to this tool (probably bot protection against non-browser clients). Instead you save
the page yourself and the tool imports it offline; it sends nothing.

1. In your own browser, logged in, open `https://forums.e-hentai.org/index.php?showuser=<your member id>` and save the
   page as HTML source only ("Save As" with "Page Source", not "Web Archive"; in Safari use "Show Page Source", then
   save it as a `.html` file).
2. Import it (from the repository root):

   ```bash
   swift run --package-path Tools/FixtureCapture fixture-capture import <FILE> --as eh/forum/profile.html
   ```

   Options: `--output DIR` (default `Packages/ErosKit/Tests/Fixtures`) and `--secrets-file PATH` (default
   `.fixture-secrets.local`). It prints `Imported local/eh/forum/profile.html` and any warnings, and exits 0.
3. **Delete the file you saved in the browser**: it still holds your name, member id and session keys.

Why local-only: the user decided on 2026-11-05 that the real forum profile page is kept on this machine only, like the
preference pages above. The page is sanitized like a capture (the nickname in `#profilename` is discovered and joins the
secrets file; session keys are masked), passes the same write gate, and is stored at
`local/eh/forum/profile.html` with its entry in `local/manifest.local.json` (the URL is a placeholder,
`showuser=1111111`). Nothing is written to `manifest.json` or `eh/forum/`. A later `capture --sites eh` keeps the
imported page and its entry. Importing again replaces it.

The import needs your username and member id to be known first (`EH_USERNAME` and `EH_IPB_MEMBER_ID` in the environment,
or the `word` and `numeric` lines of the secrets file), so they can be masked everywhere. It refuses, with exit 2 and
no page content in the message: a target other than `eh/forum/profile.html`; a web archive or binary property list, a
file that is not HTML or one larger than 5 MB; a file that is not UTF-8; a page without a `div` with `id="profilename"` holding a name, other attributes and inline elements such as `<font>` allowed (a challenge
or login page); and a page that still fails the hygiene checks after sanitizing.

## Environment variables

Credentials are read from the environment only, for example injected by `op run` from 1Password; see
`capture.env.example`. They never reach the repository, a fixture, a log or the tool's output: messages name
variables, never values.

| Variable | Required | Use |
|---|---|---|
| `EH_IPB_MEMBER_ID` | yes | Login cookie `ipb_member_id`. |
| `EH_IPB_PASS_HASH` | yes | Login cookie `ipb_pass_hash`. |
| `EH_IGNEOUS` | for ExHentai | Cookie `igneous`; the value ExHentai hands sessions it does not let in is rejected. |
| `EH_SK`, `EH_HATH_PERKS`, `EH_STAR`, `EH_YAY`, `EH_IQ`, `EH_CF_DUID` | no | Further cookies, sent if set. |
| `EH_CF_CLEARANCE` | no | Cookie `cf_clearance`; requires `EH_USER_AGENT`. |
| `EH_SP` | no | Cookie `sp`: the site profile to capture with. Must be unset for `probe-sp`, which chooses `sp` itself. |
| `EH_USER_AGENT` | no | The exact user agent of the browser the cookies came from; defaults to the app's desktop Chrome one. |
| `EH_USERNAME` | yes, for both sites | Not sent; only used to remove the username from fixtures. The plan has no forum profile page, so the username is not discovered automatically; without it the run stops before sending anything. |

Cookies go only to `e-hentai.org`, `exhentai.org` and their subdomains; image hosts such as `ehgt.org` get none.
Every request carries `nw=1` (skip the content warning) except the one for `contentWarningGallery`.

## Promises

**Read-only.** The tool only reads. It sends GET requests, plus these POSTs and nothing else:

- `api.php` of the site with the methods `gdata`, `showpage`, `imagedispatch` and `tagsuggest`;
- the image search, with the gallery cover, to `{imageLookupURL}`: the `action` of the file search form on the
  site's front page when it is https, on the site's own host or the host of the site's fallback endpoint below
  (`upld.e-hentai.org` on E-Hentai; ExHentai's fallback is on `exhentai.org` itself, so there it is the site's host
  only) and ends in `image_lookup.php`; otherwise the site's current endpoint,
  `https://upld.e-hentai.org/image_lookup.php` or `https://exhentai.org/upld/image_lookup.php` (the Flutter app's
  `https://upld.exhentai.org/image_lookup.php` answered 403 in the M0 run; JHenTai and PicImageSearch use these).
  It carries `Referer: https://<site host>/`, as a browser posting from the front page does. The cover is uploaded in its own format, taken from the cover's `Content-Type`
  (JPEG as `a.jpg`/`image/jpeg`, PNG as `a.png`/`image/png`, GIF as `a.gif`/`image/gif`, WebP as
  `a.webp`/`image/webp`), else from its file header; a cover that is neither is sent as `a.jpg`/`image/jpeg`, with a
  warning that names no value. When the `Content-Type` and the file header name different formats, the `Content-Type`
  wins and a warning names the two formats only. (In the M0 run the cover was a WebP file; uploaded as JPEG, the
  search found nothing.)

It never rates, favorites, comments, votes or changes settings: no request mentions `inline_set` (in any case,
percent-encoded, or with `.`, space, `+` or `[` for the underscore), and `uconfig.php`, `mytags`,
`gallerypopups.php` and `archiver.php` are only fetched, never posted to. Links taken from pages are followed only
to the site's own host over https (the gallery cover only over https, from wherever the site serves it). Every
request, and every redirect followed, is checked against these rules again right before it is sent.

**Gentle.** Requests go strictly one at a time, sites in the given order. Every request, and every redirect hop
followed, first waits for the app's rate limiter (`RateLimitPolicy.flutterParity`): at least 200 ms between
requests to one host, and token buckets of 5 requests refilled every 800 ms for `e-hentai.org`/`exhentai.org`, 20
every 400 ms for image hosts, 10 every 500 ms otherwise. Nothing is ever retried. The run stops at the first sign of
trouble and writes nothing:

1. HTTP 429, 509 or any 5xx;
2. a plain-text answer mentioning a ban;
3. on ExHentai, an empty or non-HTML answer to any HTML page, from the front page on (the cookies do not grant
   access, or no longer do); the not-found gallery only has to be non-empty, as the site may answer it in plain
   text, and JSON answers, the cover and the image search redirect are exempt;
4. a status the step does not expect;
5. a front page that is not in the Compact display mode.

After a 429, 509, 5xx or ban notice, wait at least one hour and ask the user before running any command of the tool
against the site again; the tool's own stop message says so too, for an agent that reads only the output.

The one exception: a 4xx answer to the image search or to its result page does not stop the run. That step is
listed as skipped (`image lookup returned HTTP 403; skipped`) with a warning that names no value, the result page is
skipped with it, and the run goes on. These two steps come last and need no login state; the account pages after
them still catch a broken session. 429, 509, 5xx and ban notices stop the run there as everywhere.

**Private.** Requests use an ephemeral session without cookie storage, cache or credential storage, and the
system's default TLS validation. A redirect is followed only when it is https on the same host and a GET (307 and
308 keep the method, so a redirected POST is not followed), after waiting for the rate limiter and passing the
read-only check, and at most 3 times per request; otherwise the 3xx answer itself is returned, which stops the run as
an unexpected status. The image search redirect is not followed at all. Responses are sanitized before anything is written, and the writer checks every fixture
and the manifest again.

## What is removed

The sanitizer fixes exactly what the hygiene checks of `EHFixtures.FixtureHygiene` flag; the rules, their patterns
and what each leaves alone are listed in `Packages/ErosKit/Tests/Fixtures/README.md`. In short:

- credentials from the environment and values in the local secrets file, in every encoded form;
- the apikey, apiuid, login cookie values (the forum's `ipb_session_id` too, since M1), the profile name, favorite
  notes and foreign IPv4 addresses
  (addresses become `203.0.113.0/24` stand-ins, notes become placeholders);
- the torrent key on `home.php` ("Your current key is:"), and the `<uid>-<key>` segment of personal torrent download
  links (`/get/`, or `/torrent/`) and `ehtracker.org` announce URLs; both are also searched for on every other page (a
  key shorter than 8 characters, a torrent key that reads as a word, whatever tag it sits in, or a uid shorter than 5
  digits, is only masked in place; a torrent key counts as a key with only ASCII letters and digits, and a digit or a
  capital letter after the first character);
- the number before `/announce` on `ehtracker.org` and the number and key segment after `/get/` (or `/torrent/`) in
  torrent download links; the key segment is also searched for everywhere, the number (5 digits or more) only when no
  page of the run uses it as a gallery id (with no older version of the gallery, it is the gallery's own public gid);
- the values of announce URLs on any other host (`/<n>/announce`), masked in place only: an ordinary link such as
  `/2024/announce` must not turn every 2024 into 1111;
- on `home.php`, every number in the element text of every section but Image Limits (today EHTracker, Total GP Gained,
  Toplists with the H@H ranks, and Moderation Power); the Image Limits numbers stay, as they cannot identify the account;
- what the site renders from the account's settings on otherwise public pages: the inline `style` of tag elements
  (class `gt`, `gtl`, `gtw`, `gtb`, quoted or not; list pages and toplists color the account's My Tags) is deleted
  whole, since having a style at all tells a tag is in My Tags; the count in "Filtered N galleries from this page" and
  the GP and Credits after "Current Funds" (also written `Current&nbsp;Funds`) on the archiver popup are masked. A
  captured page with the "Filtered" line at all is not fixed but refused (`filteredlist`): the lists are captured with
  filters disabled (see above), and only the constructed fixtures listed in `FixtureHygiene.constructedExemptions` may
  show the line;
- what a page shows of the account's favorites (`favmark`, M1): a list row's `posted_<gid>` element with a `style` or
  `title` (a favorited gallery's category color and name), anything inside a gallery page's `#fav`, a
  `#favoritelink` that says anything but "Add to Favorites", the favorites popup's `favdel` choice, and a category
  name other than the default "Favorites 0" to "Favorites 9" (uconfig's `favorite_<n>` inputs, the popup's names, a
  category icon's title and the name after it, favorites.php's `fav<n>` options). Check only, like `filteredlist`: such
  a page is refused, not rewritten (pick targets outside the favorites, or capture later). The private pages under
  `local/` show the favorites by design and pass; a constructed fixture that stands for a favorited state needs an
  entry in `FixtureHygiene.constructedExemptions`;
- what a page shows of the account's own activity (`accountmark`, M1 final fixes): its rating (stars of class `irr`,
  `irg`, `irb` or `iry`), its tag votes (class `tup` or `tdn`), its comment votes (a `comment_vote_up_<n>` or
  `comment_vote_down_<n>` with a non-empty `style`) and its own comments (`edit_comment(`). Check only, like
  `favmark`: pick targets the account has not rated, voted on or commented, or capture later. The private pages under
  `local/` pass; a constructed fixture that stands for such a state needs an entry in
  `FixtureHygiene.constructedExemptions`;
- the account as uploader, torrent uploader or commenter on a public page (`ownupload`, `owntorrent`, `owncomment`;
  user decision 2026-11-07, M2): checked by `capture` against the unmasked values before anything is masked: the
  username, the `#profilename` `home.php` shows, the names in the secrets file and the member id, in uploader links,
  the gallery's `#gdn` (linked or not), comment headers (`div.c3` after its `by:`, linked or not), the `Uploader:` of
  each torrent in the torrent popup's `#torrentinfo` and gdata's `"uploader"`, and by the app's parsers on list pages,
  gallery pages and the torrent popup. A name without a link counts only as the whole of a piece of text between tags
  (or `&nbsp;`): a name that is one of a page's fixed words (`Contact`, `Posted`) is not found in its attributes, and
  a longer name that starts with the account's (`<name>-chan`, `<name> fan`) is someone else's. Such a run is refused
  (exit 1) and writes nothing; pick other targets. The check fails closed (`owncheck`): a public page whose body is
  not UTF-8, or that a parser cannot read although it has the markup that parser reads (`#gdn` or `.c3` on a gallery
  page, `table.itg` or a gallery link on a list page, `#torrentinfo` on the torrent popup, on any element), is refused
  as well, since the check cannot tell what it shows; update the parsers, then capture again. `resanitize` runs the
  same check on the captured public fixtures against the identity it knows then (the credential variables and the
  secrets file): names masked earlier (`aaaa…`) no longer match, so it refuses when the identity has grown since
  (another account's username, a former name added to the secrets file), or when a captured page no longer reads
  with the current parsers (`owncheck`; capture it again), and then writes nothing; capture those pages again with
  other targets. `import` writes only the private forum profile page;
- the forum's session id, log-out key, `auth_key` and `md5check` (`forumkey`): 32 hex digits after `s=`, `k=`,
  `auth_key=` or `md5check=` in a query, assigned to those names or to `ipb_var_s`, `ipb_md5_check`, `secure_hash` or
  `session_id` in a script or JSON, or as the value of a hidden input with one of the four names. Masked in place, and
  searched for in every text of the run, but never written to the secrets file: they are tokens.

Separators in these URLs may be written as `/`, `\/`, `%2F`, `&#47;` or `&#x2F;`. As a fail-closed backstop, every
path segment, query value (a query item without `=` counts whole) and fragment of an `ehtracker.org` URL (with or
without a port or a path) other than `get`, `torrent`, `announce` and the info hash must end up masked:
a shape none of the rules knows makes the writer refuse, rather than slip through. The same goes for `home.php`: a
check that uses none of the rule patterns (`HomePageCheck`) runs before writing, and any digit but `1` left in element
text outside Image Limits refuses the write with a hint that the page layout has probably changed.

Masking keeps length and character classes: digits become `1`, lowercase letters `a`, uppercase letters `A`.

## Exit status

| Status | Meaning |
|---|---|
| 0 | Fixtures written (or the dry run printed); skipped steps and warnings are listed. |
| 1 | The capture or a probe stopped (see above), a request failed, a step needed for the fixture set was skipped (only the content warning and the image lookup steps may be), or the output was refused by the hygiene checks: no fixture was written and nothing was retried. A file system error while writing the fixtures can leave some files written; check the fixture directory with `git status` (the tool says so too). |
| 2 | Bad arguments, missing or invalid credentials (including `EH_SP` with more than one site), or unusable configuration (`targets.json` unreadable, unparsable or still holding a placeholder gallery, missing output directory, unreadable secrets file); nothing was sent. `import` also exits 2 when it refuses a file (see above); nothing was written. `probe-sp` also exits 2 when `EH_SP` is set or more than 3 profile numbers are given; nothing was sent. |
| 4 | `probe-structure` only: all pages were compared and some structure differs from the M0 sample. |
