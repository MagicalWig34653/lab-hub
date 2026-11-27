#!/usr/bin/env python3
"""WP-PA3V: lädt EIN großes, ERFUNDENES PDF in eine LOKALE paperless-ngx-Instanz (nur Standardbibliothek, Aufruf wie `seed.py`).
Das PDF hat eine kleine Textseite und einen eingebetteten Dateianhang aus Pseudozufallsbytes (deterministisch, nicht komprimierbar), der die Größe ausmacht. Kein großes Bild:
das Rendern der Miniatur eines großen Bildes ließ den Worker der Instanz im Container am Speicher scheitern (SIGKILL). Keine echten Daten.

Aufruf:  PA_URL=http://127.0.0.1:18000 PA_ADMIN=<benutzer> PA_PASS=<kennwort> PA_LARGE_MB=36 python3 large.py     Ausgabe: JSON {"id": <Dokument-ID>, "bytes": <Größe>}
"""
import json
import os
import random
import sys

sys.dont_write_bytecode = True   # kein __pycache__ im Repo
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from seed import call, multipart, wait_task  # noqa: E402  (liest PA_URL, PA_ADMIN, PA_PASS aus der Umgebung)


def large_pdf(megabytes):
    payload = random.Random("pa3v-large").randbytes(megabytes * 1024 * 1024)
    text = b"BT /F1 12 Tf 72 780 Td (Grosser erfundener Scan) Tj ET"
    objs = [b"<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(daten.bin) 7 0 R] >> >> >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            b"<< /Length %d >>\nstream\n%s\nendstream" % (len(text), text), b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            b"<< /Type /EmbeddedFile /Length %d >>\nstream\n%s\nendstream" % (len(payload), payload),
            b"<< /Type /Filespec /F (daten.bin) /EF << /F 6 0 R >> >>"]
    out, offsets = b"%PDF-1.4\n% synthetic pa3v\n", []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (i, o)
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offsets)
    return out + b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)


def main():
    content = large_pdf(int(os.environ.get("PA_LARGE_MB", "36")))
    body, h = multipart({"title": "Grosser Scan", "created": "2026-10-10"}, "gross.pdf", content, "application/pdf")
    print(json.dumps({"id": wait_task(call("POST", "/api/documents/post_document/", body, h)), "bytes": len(content)}))


if __name__ == "__main__":
    main()
