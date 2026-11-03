#!/usr/bin/env python3
"""Write App/Resources/<lang>.lproj/{Localizable,InfoPlist}.strings.

keys.json is the ordered list of UI strings (English, as written in code);
<lang>.json holds the translations in the same order. Refuses to write if a
translation drops or adds a format specifier or a **bold** marker, which is
also how a shifted entry shows up.

Run from the repo root:  python3 scripts/i18n/build.py
"""
import json, pathlib, re, sys

here = pathlib.Path(__file__).parent
out = pathlib.Path("App/Resources")
keys = json.loads((here / "keys.json").read_text())
info = json.loads((here / "infoplist.json").read_text())
langs = [l for l in info if l != "en"]
spec = re.compile(r"%(?:\d+\$)?(?:lld|@|d)|%%")

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

tables = {"en": keys}
errors = []
for lang in langs:
    values = json.loads((here / f"{lang}.json").read_text())
    if len(values) != len(keys):
        errors.append(f"{lang}: {len(values)} entries for {len(keys)} keys")
        continue
    for i, (k, v) in enumerate(zip(keys, values)):
        if sorted(spec.findall(k)) != sorted(spec.findall(v)):
            errors.append(f"{lang}[{i}] format mismatch: {k!r} -> {v!r}")
        if k.count("**") != v.count("**"):
            errors.append(f"{lang}[{i}] bold mismatch: {k!r} -> {v!r}")
    tables[lang] = values
if errors:
    sys.exit("\n".join(errors))

for lang, values in tables.items():
    d = out / f"{lang}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    lines = [f'"{esc(k)}" = "{esc(v)}";' for k, v in zip(keys, values)]
    (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    name, network = info[lang]
    (d / "InfoPlist.strings").write_text(
        f'"CFBundleDisplayName" = "{esc(name)}";\n"CFBundleName" = "{esc(name)}";\n'
        f'"NSLocalNetworkUsageDescription" = "{esc(network)}";\n', encoding="utf-8")
print(f"wrote {len(tables)} languages x {len(keys)} strings")
