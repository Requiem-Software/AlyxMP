"""Build the HL2-style HUD overrides for NoVR from NoVR's own files and Half-Life 2's originals.

Writes mod/game/alyxmp_hud/{scripts/hudlayout.res, resource/clientscheme.res, scripts/hudanimations.txt}.
The installer mounts that folder ahead of NoVR (gameinfo.gi "Game alyxmp_hud").

  python tools/make_hl2_hud.py NOVR_DIR HL2_DIR
    NOVR_DIR: NoVR's files extracted from game/novr/pak01_dir.vpk (tools/vpk.py get ...)
    HL2_DIR:  Half-Life 2's hl2 folder (scripts/hudlayout.res etc. are loose files there)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "mod", "game", "alyxmp_hud")

# elements HL2 lays out differently from NoVR; everything else (wrist pockets, crosshair...) stays NoVR's
LAYOUT_FROM_HL2 = ["HudHealth", "HudAmmo", "HudAmmoSecondary", "HudSuitPower", "HudWeaponSelection",
                   "HudHistoryResource", "HudPoisonDamageIndicator", "HudFlashlight"]
COLORS_FROM_HL2 = ["FgColor", "BgColor", "BrightFg", "BrightBg", "DamagedBg", "DamagedFg", "BrightDamagedFg",
                   "SelectionNumberFg", "SelectionTextFg", "SelectionEmptyBoxBg", "SelectionBoxBg",
                   "SelectionSelectedBoxBg", "ZoomReticleColor", "AuxPowerLowColor", "AuxPowerHighColor",
                   "AuxPowerDisabledAlpha"]
FONTS_FROM_HL2 = ["HudNumbersSmall", "HudSelectionNumbers", "HudHintTextSmall", "HudSelectionText"]


def read(path):
    raw = open(path, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    return raw.decode("utf-8", "replace").lstrip("﻿")


def find_block(text, name, start=0):
    """(start, end) of '"name" { ... }' (or 'name { ... }'), braces balanced, comments skipped."""
    # PC blocks may carry a [$WIN32] (NoVR) or [!$DECK] (current HL2) tag; [$X360] / [$DECK] variants are skipped
    m = re.compile(r'(?m)^[ \t]*"?' + re.escape(name) + r'"?[ \t]*(?:\[(?:\$WIN32|!\$DECK)\][ \t]*)?(?://[^\n]*)?\r?\n[\s]*\{').search(text, start)
    if not m:
        return None
    i = text.index("{", m.start())
    depth = 0
    j = i
    while j < len(text):
        c = text[j]
        if c == "/" and text[j:j + 2] == "//":
            j = text.index("\n", j) if "\n" in text[j:] else len(text)
            continue
        if c == '"':
            j = text.index('"', j + 1) + 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return m.start(), j + 1
        j += 1
    return None


def replace_block(dst, src, name, within=None):
    """put src's block NAME in place of dst's (inside the block WITHIN, if given)"""
    def span(text):
        if within:
            outer = find_block(text, within)
            if not outer:
                return None
            inner = find_block(text, name, outer[0] + 1)
            return inner if inner and inner[1] <= outer[1] else None
        return find_block(text, name)

    d, s = span(dst), span(src)
    if not d or not s:
        print(f"  ! {name}: {'not in NoVR' if not d else 'not in HL2'}")
        return dst
    # keep NoVR's header line (its platform tag), take HL2's body
    d_body = dst.index("{", d[0])
    s_body = src.index("{", s[0])
    return dst[:d_body] + src[s_body:s[1]] + dst[d[1]:]


def set_setting(text, key, value, within="BaseSettings"):
    outer = find_block(text, within)
    body = text[outer[0]:outer[1]]
    pat = re.compile(r'(?m)^([ \t]*"?' + re.escape(key) + r'"?[ \t]+)"[^"]*"')
    if pat.search(body):
        body = pat.sub(lambda m: m.group(1) + '"' + value + '"', body, count=1)
    else:
        k = body.rindex("}")
        body = body[:k] + f'\t\t"{key}"\t\t"{value}"\n\t' + body[k:]
    return text[:outer[0]] + body + text[outer[1]:]


def setting(text, key, within="BaseSettings"):
    outer = find_block(text, within)
    m = re.search(r'(?m)^[ \t]*"?' + re.escape(key) + r'"?[ \t]+"([^"]*)"', text[outer[0]:outer[1]])
    return m.group(1) if m else None


def main(novr, hl2):
    os.makedirs(os.path.join(OUT, "scripts"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "resource"), exist_ok=True)

    layout = read(os.path.join(novr, "scripts", "hudlayout.res"))
    hl2_layout = read(os.path.join(hl2, "scripts", "hudlayout.res"))
    for el in LAYOUT_FROM_HL2:
        layout = replace_block(layout, hl2_layout, el)
    header = "// Alyx Multiplayer: NoVR's HUD layout with Half-Life 2's health/ammo/selection boxes (exact HL2 values)\n"
    open(os.path.join(OUT, "scripts", "hudlayout.res"), "w", encoding="utf-8", newline="\r\n").write(header + layout)

    scheme = read(os.path.join(novr, "resource", "clientscheme.res"))
    hl2_scheme = read(os.path.join(hl2, "resource", "clientscheme.res"))
    for key in COLORS_FROM_HL2:
        v = setting(hl2_scheme, key)
        if v is not None:
            scheme = set_setting(scheme, key, v)
    for font in FONTS_FROM_HL2:
        scheme = replace_block(scheme, hl2_scheme, font, within="Fonts")
    header = "// Alyx Multiplayer: NoVR's scheme with Half-Life 2's HUD colors and fonts\n"
    open(os.path.join(OUT, "resource", "clientscheme.res"), "w", encoding="utf-8", newline="\r\n").write(header + scheme)

    anims = read(os.path.join(hl2, "scripts", "hudanimations.txt"))
    novr_anims = read(os.path.join(novr, "scripts", "hudanimations.txt"))
    extra = []
    for m in re.finditer(r"(?m)^\s*event\s+(\S+)", novr_anims):
        name = m.group(1)
        if not re.search(r"(?m)^\s*event\s+" + re.escape(name) + r"\b", anims):
            b = find_block(novr_anims, "event " + name) or find_block(novr_anims, name)
            if b:
                extra.append(novr_anims[b[0]:b[1]])
    anims = "// Alyx Multiplayer: Half-Life 2's HUD animations, plus NoVR's per-weapon ammo events\n" + anims + "\n\n" + "\n\n".join(extra) + "\n"
    open(os.path.join(OUT, "scripts", "hudanimations.txt"), "w", encoding="utf-8", newline="\r\n").write(anims)
    print("wrote", OUT, f"(+{len(extra)} NoVR animation events)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
