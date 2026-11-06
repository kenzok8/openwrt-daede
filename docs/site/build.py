#!/usr/bin/env python3
"""构建 daede 文档站。

只用 Python 标准库：读取 site.json 与 content/ 下的正文片段，套上统一布局，
顺手做一遍自检（锚点重复、站内死链、导航漏页），最后输出到 .build/docs-site。

    python3 docs/site/build.py                 # 构建
    python3 docs/site/build.py --check         # 只自检，不写文件
    python3 docs/site/build.py --output custom # 指定输出目录
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import sys
from pathlib import Path
from string import Template
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]

HEADING = re.compile(r"<h([23])([^>]*)>(.*?)</h\1>", re.S)
ID_ATTR = re.compile(r'id="([^"]+)"')
LINK_ATTR = re.compile(r'(?:href|src)="([^"]+)"')
TAG = re.compile(r"<[^>]+>")

LAYOUT = Template(
    """<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="color-scheme" content="light dark" />
    <title>$title$title_suffix</title>
    <meta name="description" content="$description" />
    <link rel="canonical" href="$canonical" />
    <link rel="icon" href="assets/logo.png" type="image/png" />
    <link rel="apple-touch-icon" href="assets/logo.png" />
    <link rel="stylesheet" href="assets/site.css" />
    <script src="assets/site.js" defer></script>
  </head>
  <body data-page="$page">
    <a class="skip-link" href="#content">跳到正文</a>
    <header class="header">
      <a class="brand" href="index.html">
        <img src="assets/logo.png" width="28" height="28" alt="" />
        <span>$site<small>$subtitle</small></span>
      </a>
      <button class="search-trigger" type="button" data-search-open>
        <span aria-hidden="true">⌕</span> 搜索文档 <kbd>Ctrl K</kbd>
      </button>
      <nav class="header-links">
        <a href="https://github.com/$repo">GitHub ↗</a>
      </nav>
      <button class="icon-button" id="theme-toggle" type="button" aria-label="切换深浅主题" aria-pressed="false">◐</button>
      <button class="icon-button menu-button" id="menu-toggle" type="button" aria-controls="sidebar" aria-expanded="false">目录</button>
    </header>
    <div class="layout">
      <aside class="sidebar" id="sidebar">
$sidebar
        <div class="sidebar-footer">
          <span class="version">$version</span>
        </div>
      </aside>
      <main id="content" class="content">
$content
        <footer class="page-footer">
          <a href="https://github.com/$repo/blob/main/docs/site/content/$page">编辑此页</a>
          <span>$site 文档 · GPL-3.0</span>
        </footer>
      </main>
    </div>
    <div class="search-overlay" id="search" hidden>
      <div class="search-box">
        <input type="search" id="search-input" placeholder="搜索标题与正文…" autocomplete="off" spellcheck="false" />
        <button class="icon-button" type="button" data-search-close aria-label="关闭搜索">✕</button>
      </div>
      <ul class="search-results" id="search-results"></ul>
    </div>
  </body>
</html>
"""
)


def read_site() -> dict:
    return json.loads((ROOT / "site.json").read_text(encoding="utf-8"))


def read_version(site: dict) -> str:
    """版本号从 Makefile 读，文档不会比包版本落后。"""
    makefile = REPO / site["version_file"]
    if not makefile.is_file():
        return ""
    text = makefile.read_text(encoding="utf-8")
    version = re.search(r"^PKG_VERSION:=(.+)$", text, re.M)
    release = re.search(r"^PKG_RELEASE:=(.+)$", text, re.M)
    if not version:
        return ""
    return version.group(1).strip() + (f"-r{release.group(1).strip()}" if release else "")


def pages(site: dict) -> list[dict]:
    return [item | {"group": group["group"]} for group in site["nav"] for item in group["items"]]


def strip_tags(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(TAG.sub(" ", text))).strip()


def collect_ids(body: str, page: str) -> set[str]:
    ids: set[str] = set()
    for value in ID_ATTR.findall(body):
        if value in ids:
            raise SystemExit(f"{page}: 锚点 id 重复 —— {value}")
        ids.add(value)
    return ids


def check_structure(body: str, page: str) -> list[str]:
    """Pages 部署在 /openwrt-daede/ 子路径下，绝对路径会 404；正文要在第一个 h2 之前出现 h1。"""
    problems = []
    h1 = body.find("<h1")
    h2 = body.find("<h2")
    if h1 < 0:
        problems.append(f"{page}: 正文缺少 <h1>")
    elif h2 >= 0 and h2 < h1:
        problems.append(f"{page}: <h1> 必须出现在第一个 <h2> 之前")
    if 'href="/' in body or 'src="/' in body:
        problems.append(f"{page}: 出现以 / 开头的绝对路径（Pages 部署在子路径下会 404）")
    return problems


def check_links(body: str, page: str, known: set[str], assets: set[str]) -> list[str]:
    problems = []
    for raw in LINK_ATTR.findall(body):
        if raw.startswith(("http://", "https://", "mailto:", "//")):
            continue
        target = urlsplit(raw)
        path = target.path
        if not path:
            continue  # 纯锚点，交给浏览器
        if path in known or path in assets:
            continue
        problems.append(f"{page}: 站内链接指向不存在的文件 —— {raw}")
    return problems


def build(site: dict, output: Path, check_only: bool) -> list[str]:
    errors: list[str] = []
    known = {item["page"] for item in pages(site)}
    asset_dir = ROOT / "assets"
    assets = {f"assets/{p.name}" for p in asset_dir.iterdir() if p.is_file()} if asset_dir.is_dir() else set()

    content_dir = ROOT / "content"
    on_disk = {p.name for p in content_dir.glob("*.html")}
    for orphan in sorted(on_disk - known):
        errors.append(f"content/{orphan}: 没有出现在 site.json 导航里")

    rendered: dict[str, str] = {}
    index: list[dict] = []
    for item in pages(site):
        page = item["page"]
        source = content_dir / page
        if not source.is_file():
            errors.append(f"content/{page}: 导航里列了但文件不存在")
            continue
        body = source.read_text(encoding="utf-8")
        ids = collect_ids(body, page)
        errors.extend(check_structure(body, page))
        errors.extend(check_links(body, page, known, assets))

        headings = []
        for level, attrs, text in HEADING.findall(body):
            match = ID_ATTR.search(attrs)
            if not match:
                errors.append(f"{page}: 标题缺少 id —— {strip_tags(text)}")
                continue
            headings.append({"level": int(level), "id": match.group(1), "text": strip_tags(text)})

        rendered[page] = body
        index.append(
            {
                "page": page,
                "title": item["title"],
                "group": item["group"],
                "headings": headings,
                "text": strip_tags(body)[:1200],
            }
        )

    if errors:
        return errors
    if check_only:
        return []

    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    for item in pages(site):
        page = item["page"]
        sidebar = ['        <nav aria-label="文档目录">']
        for group in site["nav"]:
            sidebar.append(f'          <p class="nav-label">{html.escape(group["group"])}</p>')
            for entry in group["items"]:
                current = ' aria-current="page"' if entry["page"] == page else ""
                sidebar.append(f'          <a href="{entry["page"]}"{current}>{html.escape(entry["title"])}</a>')
        sidebar.append("        </nav>")

        title = site["title"] if page == "index.html" else f'{item["title"]} · {site["title"]}'
        document = LAYOUT.substitute(
            title=html.escape(title),
            title_suffix="" if page == "index.html" else "",
            description=html.escape(item.get("summary", site["description"])),
            canonical=site["base_url"] + page,
            page=page.removesuffix(".html"),
            repo=site["repo"],
            site=html.escape(site["title"]),
            subtitle=html.escape(site["subtitle"]),
            sidebar="\n".join(sidebar),
            content=rendered[page],
            version=f'v{html.escape(read_version(site))}' if read_version(site) else "",
        )
        (output / page).write_text(document, encoding="utf-8")

    if asset_dir.is_dir():
        shutil.copytree(asset_dir, output / "assets")

    (output / "search-index.json").write_text(
        json.dumps(index, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    (output / "404.html").write_text(
        LAYOUT.substitute(
            title=f"页面不存在 · {site['title']}",
            title_suffix="",
            description="页面不存在",
            canonical=site["base_url"],
            page="404",
            repo=site["repo"],
            site=html.escape(site["title"]),
            subtitle=html.escape(site["subtitle"]),
            sidebar='        <nav aria-label="文档目录"><a href="index.html">返回文档首页</a></nav>',
            content='        <h1>页面不存在</h1>\n        <p>链接可能已经调整，<a href="index.html">回到文档首页</a>。</p>',
            version="",
        ),
        encoding="utf-8",
    )
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description="构建 daede 文档站")
    parser.add_argument("--output", default=str(REPO / ".build/docs-site"), help="输出目录")
    parser.add_argument("--check", action="store_true", help="只做自检，不写文件")
    args = parser.parse_args()

    site = read_site()
    errors = build(site, Path(args.output), args.check)
    if errors:
        for line in errors:
            print(f"错误: {line}", file=sys.stderr)
        return 1
    if args.check:
        print("自检通过")
        return 0
    print(f"已生成 {len(pages(site))} 页 → {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
