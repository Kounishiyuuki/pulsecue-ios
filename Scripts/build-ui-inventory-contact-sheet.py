#!/usr/bin/env python3
"""Build local HTML contact sheets for the UI inventory (no runtime deps).

Scans an output directory produced by capture-ui-inventory.sh and writes:
  - one contact sheet per screen group (NN-group/_contact.html)
  - one overall atlas (index.html) with readable thumbnails

Each thumbnail shows the group, route-derived filename, and path — making it
easy to upload grouped images to Stitch. HTML + images are LOCAL artifacts and
are never committed.

Usage:
  python3 Scripts/build-ui-inventory-contact-sheet.py [--output build/ui-inventory]
"""
import argparse
import html
import os
import sys

CSS = """
body{font-family:-apple-system,Helvetica,Arial,sans-serif;background:#0f1115;color:#e8eaed;margin:24px}
h1{font-size:20px}h2{font-size:16px;margin-top:28px;border-bottom:1px solid #333;padding-bottom:6px}
.grid{display:flex;flex-wrap:wrap;gap:16px}
.card{width:220px}.card img{width:220px;border:1px solid #333;border-radius:10px;background:#000}
.cap{font-size:12px;color:#aab;margin-top:6px;word-break:break-all}
a{color:#7ab7ff}
"""


def groups(root):
    if not os.path.isdir(root):
        return []
    out = []
    for name in sorted(os.listdir(root)):
        gdir = os.path.join(root, name)
        if not os.path.isdir(gdir):
            continue
        pngs = sorted(f for f in os.listdir(gdir) if f.lower().endswith(".png"))
        if pngs:
            out.append((name, pngs))
    return out


def card(rel_img, label):
    return (
        f'<div class="card"><a href="{html.escape(rel_img)}">'
        f'<img src="{html.escape(rel_img)}" loading="lazy"></a>'
        f'<div class="cap">{html.escape(label)}</div></div>'
    )


def write_group_sheet(root, name, pngs):
    cards = "\n".join(card(p, f"{name} / {p}") for p in pngs)
    doc = f"<!doctype html><meta charset=utf-8><title>{html.escape(name)}</title><style>{CSS}</style>" \
          f"<h1>UI Inventory — {html.escape(name)}</h1><div class=grid>{cards}</div>"
    with open(os.path.join(root, name, "_contact.html"), "w") as f:
        f.write(doc)


def write_index(root, gs):
    sections = []
    for name, pngs in gs:
        cards = "\n".join(card(os.path.join(name, p), f"{name} / {p}") for p in pngs)
        sections.append(
            f'<h2>{html.escape(name)} '
            f'(<a href="{html.escape(name)}/_contact.html">group sheet</a>) '
            f'— {len(pngs)}枚</h2><div class=grid>{cards}</div>'
        )
    total = sum(len(p) for _, p in gs)
    doc = f"<!doctype html><meta charset=utf-8><title>UI Inventory</title><style>{CSS}</style>" \
          f"<h1>PulseCue UI Inventory — {total}枚 / {len(gs)}グループ</h1>" + "\n".join(sections)
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write(doc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="build/ui-inventory")
    args = ap.parse_args()
    gs = groups(args.output)
    if not gs:
        print(f"no images found under {args.output}", file=sys.stderr)
        return 1
    for name, pngs in gs:
        write_group_sheet(args.output, name, pngs)
    write_index(args.output, gs)
    total = sum(len(p) for _, p in gs)
    print(f"contact sheets: {args.output}/index.html  ({total} images, {len(gs)} groups)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
