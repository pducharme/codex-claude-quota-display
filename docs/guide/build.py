"""Build the static user guide with Python's standard library."""
import html
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PAGES = [
    ('index', 'Bienvenue', 'Commencer'),
    ('demarrage', 'Votre première page', 'Commencer'),
    ('installation', 'Installer et mettre à jour', 'Commencer'),
    ('composer', 'Composer une page', 'Designer'),
    ('polices', 'Polices et lisibilité', 'Designer'),
    ('publication', 'Envoyer aux mini-écrans', 'Designer'),
    ('catalogue', 'Les 26 usages', 'Modèles et connexions'),
    ('home-assistant', 'Home Assistant et Sonos', 'Modèles et connexions'),
    ('avions', 'Dans le ciel', 'Modèles et connexions'),
    ('depannage', 'Résoudre un problème', 'Aide'),
    ('confidentialite', 'Données et confidentialité', 'Aide'),
    ('api', 'API et automatisation', 'Référence'),
    ('versions', 'Versions et disponibilité', 'Référence'),
]

def build(destination):
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'assets', destination / 'assets', dirs_exist_ok=True)
    records = []
    for i, (slug, title, group) in enumerate(PAGES):
        content = (ROOT / 'pages' / (slug + '.html')).read_text()
        headings = re.findall(r'<h2 id="([^"]+)">(.*?)</h2>', content)
        nav, previous_group = '', None
        for other, label, section in PAGES:
            if section != previous_group:
                nav += '<h2>' + section + '</h2>'
                previous_group = section
            current = ' aria-current="page"' if slug == other else ''
            nav += f'<a href="{other}.html"{current}>{label}</a>'
        toc = ''.join(f'<a href="#{key}">{label}</a>' for key, label in headings)
        footer = ''
        if i:
            footer += f'<a href="{PAGES[i-1][0]}.html"><small>Précédent</small>{PAGES[i-1][1]}</a>'
        if i + 1 < len(PAGES):
            footer += f'<a href="{PAGES[i+1][0]}.html"><small>Suivant</small>{PAGES[i+1][1]}</a>'
        output = f'''<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="{html.escape(title)} : guide du Designer pour les mini-écrans Quota Display."><title>{title} — Guide Quota Display</title><link rel="stylesheet" href="assets/guide.css"><script src="assets/guide.js" defer></script></head>
<body><a class="skip" href="#contenu">Aller au contenu</a>
<header><a class="brand" href="index.html"><span class="screen-mark" aria-hidden="true">▰</span>Quota Display <span>Guide du Designer</span></a><button id="menu-toggle" aria-expanded="false" aria-controls="navigation">Rubriques</button><label class="search-label">Rechercher<input id="search" type="search" placeholder="Rechercher dans le guide…" autocomplete="off"></label><a href="https://github.com/pducharme/codex-claude-quota-display">GitHub</a></header>
<div class="layout"><nav id="navigation" aria-label="Rubriques">{nav}</nav><main id="contenu"><div id="search-results" hidden aria-live="polite"></div><article><p class="breadcrumb">{group}</p><h1>{title}</h1>{content}</article><div class="pagination">{footer}</div><footer>Guide en français · Version de développement du Designer · <a href="https://github.com/pducharme/codex-claude-quota-display/issues">Signaler un problème</a></footer></main><aside aria-label="Sur cette page"><strong>Sur cette page</strong>{toc}</aside></div></body></html>'''
        (destination / (slug + '.html')).write_text(output)
        plain = html.unescape(re.sub('<[^>]+>', ' ', content))
        records.append(dict(title=title, url=slug + '.html', text=re.sub(r'\s+', ' ', plain)))
    (destination / 'search.json').write_text(json.dumps(records, ensure_ascii=False))
    (destination / '.nojekyll').touch()
    # Every internal page, resource and heading link must resolve before publication.
    from html.parser import HTMLParser
    class Links(HTMLParser):
        def __init__(self): super().__init__(); self.links=[]; self.ids=set()
        def handle_starttag(self, tag, attrs):
            attrs=dict(attrs)
            if 'id' in attrs: self.ids.add(attrs['id'])
            for attr in ('href','src'):
                if attr in attrs: self.links.append(attrs[attr])
    parsed={}
    for file in destination.glob('*.html'):
        parser=Links(); parser.feed(file.read_text()); parsed[file.name]=parser
    for name, parser in parsed.items():
        for link in parser.links:
            if link.startswith(('https:', 'http:', 'mailto:')): continue
            file, _, fragment = link.partition('#')
            file=file or name
            assert (destination/file).is_file(), f'{name}: missing {link}'
            if fragment: assert fragment in parsed[file].ids, f'{name}: missing heading {link}'
    print(f'{len(PAGES)} pages built; all local links checked: {destination}')

if __name__ == '__main__':
    build(Path(sys.argv[1]) if len(sys.argv)>1 else ROOT.parents[1] / '.build' / 'guide')
