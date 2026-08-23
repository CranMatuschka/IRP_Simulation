#!/usr/bin/env python3
"""Verify analysis/p676_annex1.m against the ITU-R P.676-13 Word document.

THE PRIMARY-SOURCE CHECK. Until now the oxygen table had two independent
transcriptions agreeing (ITU-Rpy v13 and MathWorks v10) but the WATER-VAPOUR table
had only one, because it was revised after v10 so no v10 implementation could
corroborate it. The Recommendation's PDF is a scanned image with no text layer; the
Word version stores both tables as real Word tables, so it can be parsed.
"""
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
NUM = re.compile(r"^-?\d*\.?\d+$")


def norm(s):
    # Three document conventions to undo:
    #   EN DASH / MINUS SIGN for the minus                     "–1.172"  -> "-1.172"
    #   leading zero omitted                                   ".1079"   -> ".1079" (ok)
    #   SPACE (and NBSP) as the thousands separator            "1 780.0" -> "1780.0"
    s = s.replace("–", "-").replace("−", "-").replace(",", ".")
    return s.replace(" ", "").replace(" ", "").strip()


def docx_rows(path):
    with zipfile.ZipFile(path) as z:
        root = ET.fromstring(z.read("word/document.xml"))
    out = []
    for tbl in root.iter(W + "tbl"):
        for tr in tbl.iter(W + "tr"):
            cells = [norm("".join(t.text or "" for t in tc.iter(W + "t")))
                     for tc in tr.findall(W + "tc")]
            if len(cells) == 7 and NUM.match(cells[0]):
                out.append([float(c) for c in cells])
    return out


def matlab_table(path, marker_start, marker_end):
    src = open(path, encoding="utf-8").read()
    seg = src.split(marker_start, 1)[1].split(marker_end, 1)[0]
    rows = []
    for line in seg.splitlines():
        line = line.split("%")[0].strip().rstrip(";").rstrip("]").rstrip("...").strip()
        line = line.rstrip(";").strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 7 and all(NUM.match(p) for p in parts):
            rows.append([float(p) for p in parts])
    return rows


def compare(name, mine, theirs):
    theirs = {round(r[0], 6): r for r in theirs}
    print(f"\n===== {name}: {len(mine)} rows in p676_annex1.m, "
          f"{len(theirs)} candidate rows from the Recommendation =====")
    bad = 0
    missing = 0
    for r in mine:
        key = round(r[0], 6)
        if key not in theirs:
            print(f"  !! f0={r[0]} NOT FOUND in the Recommendation")
            missing += 1
            continue
        ref = theirs[key]
        for j in range(7):
            if abs(r[j] - ref[j]) > 1e-9:
                print(f"  !! f0={r[0]} col{j}: mine {r[j]} vs source {ref[j]}")
                bad += 1
    print(f"  -> {len(mine)-missing} matched, {bad} value mismatches, {missing} not found")
    return bad, missing


def main(docx, mfile):
    src_rows = docx_rows(docx)
    oxy = matlab_table(mfile, "oxy = [", "];")
    wat = matlab_table(mfile, "wat = [", "];")
    b1, m1 = compare("OXYGEN (Table 1)", oxy, src_rows)
    b2, m2 = compare("WATER VAPOUR (Table 2)", wat, src_rows)
    print("\n" + ("ALL ROWS VERIFIED AGAINST THE RECOMMENDATION"
                  if (b1 + b2 + m1 + m2) == 0 else
                  f"DISCREPANCIES: {b1+b2} values, {m1+m2} missing"))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
