# git-cowork landing page

A static one-page site for git-cowork, plus Impressum and Datenschutz. It has no
build step, no dependencies, no cookies, no tracking and no external requests.
Fonts and images are served from `assets/`.

```
index.html          landing page (English)
impressum.html      Impressum, smao GmbH (German)
datenschutz.html    privacy policy (German)
robots.txt, sitemap.xml
assets/site.css     styles and self-hosted fonts
assets/site.js      copy buttons
assets/fonts/       Bricolage Grotesque, Instrument Sans, JetBrains Mono (SIL OFL)
assets/img/         icon and screenshots (copies of docs/images)
```

## Before deploying

1. **Domain.** Replace `DOMAIN` with the final host name in `index.html`
   (canonical, og:url, og:image), `robots.txt` and `sitemap.xml`.
2. **Hoster.** In `datenschutz.html`, fill in the two red placeholders: the
   hoster's name and address, and how long it keeps server logs.
3. **Data processing agreement.** Sign an AVV (Art. 28 DSGVO) with the hoster,
   as the privacy page says.
4. **HTTPS only.** The privacy page says the site is served only over HTTPS.
5. **Legal check.** The Impressum copies smao.ai's own (checked 2026-11-07),
   including Luigi Monzione as "Inhaltlich verantwortlich". Change it if someone
   else is responsible for this site. This is not legal advice.
6. **GitHub repo.** The links go to github.com/michael-smao/git-cowork, so the
   repo must be public first.

This lists anything still open:

```bash
grep -rn 'DOMAIN\|class="todo"' site
```

## Preview locally

```bash
python3 -m http.server 8080 --directory site
```

## Deploy

Upload the whole folder as is to any static host. If the screenshots in
`docs/images` change, copy them to `assets/img` again.
