#!/usr/bin/env python3
"""Erzeugt die synthetische Test-Fixture `export/` (WP-D6): ein kleiner Export im Stil eines `document_exporter`-Verzeichnisses
(manifest.json + Dateien). Alles ist erfunden und deterministisch (kein Zufall, keine Uhrzeit): ein zweiter Lauf liefert byteidentische Dateien.
Keine echten Daten, keine Texte oder Testdaten aus Paperless-ngx (GPL-3.0); nur die Struktur der Funktionen ist nachgebaut.

Aufruf:  python3 generate.py          (schreibt nach ./export, überschreibt vorhandene Dateien)
Prüfung: python3 generate.py --check  (Exit 1, wenn export/ vom Generator abweicht)
"""
import hashlib
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "export")


def pdf(text_lines, seed):
    """Minimales, gültiges PDF mit Textschicht (eine Seite, Helvetica)."""
    stream = "BT /F1 12 Tf 72 720 Td 14 TL " + " T* ".join("(%s) Tj" % t.replace("(", "[").replace(")", "]") for t in text_lines) + " ET"
    objs = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    body = "%PDF-1.4\n% synthetic fixture " + seed + "\n"
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(body))
        body += "%d 0 obj\n%s\nendobj\n" % (i, o)
    xref = len(body)
    body += "xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        body += "%010d 00000 n \n" % off
    body += "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return body.encode("latin-1")


def png(seed, size=24):
    """Kleines Graustufen-PNG mit deterministischem Muster (steht für einen Scan)."""
    h = hashlib.sha256(seed.encode()).digest()
    rows = b""
    for y in range(size):
        rows += b"\x00" + bytes(h[(x + y * 3) % 32] ^ ((x * y) & 0xFF) for x in range(size))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 0, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def md5(b):
    return hashlib.md5(b).hexdigest()


files = {}
manifest = []


def ref(model, pk, **fields):
    manifest.append({"model": model, "pk": pk, "fields": fields})


# Benutzer und Gruppen: nur Rauschen, das der Import nie lesen darf (enthält ein Kanarien-Kennwort-Hash)
ref("auth.user", 1, username="fixture_user_a", password="pbkdf2_sha256$synthetic$canary-D6-hash", email="user-a@example.org", is_superuser=True)
ref("auth.user", 2, username="fixture_user_b", password="pbkdf2_sha256$synthetic$canary-D6-hash-b", email="user-b@example.org", is_superuser=False)
ref("auth.group", 1, name="fixture_group")

for pk, name, match, algo in [(1, "Muster Strom GmbH", "strom energie", 1), (2, "Beispiel Versicherung AG", "Beispiel Versicherung", 3),
                              (3, "Fiktiv Handwerk", "", 6), (4, "Erfunden Verlag", "verlag.*", 4)]:
    ref("documents.correspondent", pk, name=name, match=match, matching_algorithm=algo, is_insensitive=True, owner=1)
for pk, name, match, algo in [(1, "Rechnung", "rechnung invoice", 1), (2, "Vertrag", "", 0), (3, "Brief", "", 0)]:
    ref("documents.documenttype", pk, name=name, match=match, matching_algorithm=algo, is_insensitive=True, owner=1)
for pk, name, color, inbox in [(1, "Steuer", "#a6cee3", False), (2, "steuer", "#1f78b4", False), (3, "Versicherung", "#b2df8a", False),
                               (4, "Versicherungen", "#33a02c", False), (5, "Wichtig", "#fb9a99", False), (6, "Eingang", "#e31a1c", True)]:
    ref("documents.tag", pk, name=name, color=color, is_inbox_tag=inbox, match="", matching_algorithm=0, is_insensitive=True, owner=1)
ref("documents.storagepath", 1, name="Jahr und Korrespondent", path="{{ created_year }}/{{ correspondent }}/{{ title }}", match="", matching_algorithm=0, owner=1)
ref("documents.storagepath", 2, name="Nach Benutzer", path="{{ owner_username }}/{{ title | lower }}", match="", matching_algorithm=0, owner=1)
ref("documents.customfield", 1, name="Betrag", data_type="monetary", extra_data=None)
ref("documents.customfield", 2, name="Referenz", data_type="string", extra_data=None)
ref("documents.customfield", 3, name="Fällig am", data_type="date", extra_data=None)

# (id, title, kind, corr, type, path, tags, asn, created, added, content, archive?, checksum?)
DOCS = [
    (101, "Stromrechnung Januar 2023", "pdf", 1, 1, 1, [1, 5], 1, "2023-02-01", "2023-02-03T09:15:00.000000Z", "Stromrechnung Januar 2023 Betrag 84,20 Euro Zaehlernummer 4711", False, True),
    (102, "Stromrechnung Februar 2023", "pdf", 1, 1, 1, [2], 2, "2023-03-01", "2023-03-02T08:00:00.000000Z", "Stromrechnung Februar 2023 Betrag 79,90 Euro", False, True),
    (103, "Haftpflicht Police", "pdf", 2, 2, None, [3], 3, "2022-12-15", "2023-01-04T10:30:00.000000Z", "Haftpflichtversicherung Police Nummer HP-0815 Laufzeit ein Jahr", False, True),
    (104, "Versicherungsnachtrag", "pdf", 2, 2, 2, [4], 4, "2023-04-10", "2023-04-11T12:00:00.000000Z", "Nachtrag zur Police HP-0815 Aenderung der Deckungssumme", False, True),
    (105, "Handwerker Angebot", "pdf", 3, 1, None, [5, 6], 17, "2023-05-20", "2023-05-21T07:45:00.000000Z", "Angebot Dachrinne reinigen pauschal 250 Euro", False, True),
    (106, "Brief vom Verlag", "pdf", 4, 3, None, [], None, "2023-06-01", "2023-06-02T15:20:00.000000Z", "Sehr geehrte Damen und Herren, wir bedanken uns fuer Ihr Abonnement", False, True),
    (107, "Scan Quittung", "scan", 3, 1, None, [6], 5, "2023-06-12", "2023-06-13T09:00:00.000000Z", "Quittung Handwerk Betrag 45 Euro bar bezahlt", True, True),
    (108, "Scan Vertrag", "scan", 2, 2, None, [], 6, "2023-07-01", "2023-07-02T09:00:00.000000Z", "Vertrag ueber Wartungsarbeiten Laufzeit zwei Jahre", True, True),
    (109, "Scan ohne Text", "scan", None, None, None, [], None, "2023-07-15", "2023-07-16T11:11:00.000000Z", "", False, True),
    (110, "Notiz ohne Pruefsumme", "pdf", None, 3, None, [], None, "2023-08-01", "2023-08-02T13:13:00.000000Z", "Notiz fuer den Test: dieser Eintrag hat keine Pruefsumme im Manifest", False, False),
]

for (pk, title, kind, corr, typ, path, tags, asn, created, added, content, archive, checksum) in DOCS:
    name = "%07d" % pk
    if kind == "pdf":
        data = pdf([title] + content.split(". "), "d%d" % pk)
        fname = name + ".pdf"
    else:
        data = png("scan-%d" % pk)
        fname = name + ".png"
    files[fname] = data
    fields = dict(title=title, content=content, correspondent=corr, document_type=typ, storage_path=path, tags=tags, created=created, added=added + "" if added else None,
                  checksum=md5(data) if checksum else "", archive_serial_number=asn, mime_type="application/pdf" if kind == "pdf" else "image/png",
                  filename=fname, owner=1)
    entry = {"model": "documents.document", "pk": pk, "fields": fields, "__exported_file_name__": fname, "__exported_thumbnail_name__": "thumbnails/%s.webp" % name}
    if archive:
        adata = pdf([title, content], "a%d" % pk)
        files["archive/" + name + ".pdf"] = adata
        fields["archive_checksum"] = md5(adata)
        entry["__exported_archive_name__"] = "archive/" + name + ".pdf"
    manifest.append(entry)

ref("documents.note", 1, note="Erste Notiz zur Police: Unterlagen liegen im Ordner Versicherung.", created="2023-01-05T10:00:00Z", document=103, user=1)
ref("documents.note", 2, note="Zweite Notiz: Beitrag jaehrlich zahlbar.", created="2023-01-06T10:00:00Z", document=103, user=1)
ref("documents.note", 3, note="Vertrag Wartung: Kuendigungsfrist beachten.", created="2023-07-03T10:00:00Z", document=108, user=2)

ref("documents.customfieldinstance", 1, document=101, field=1, value_monetary="EUR84.20")
ref("documents.customfieldinstance", 2, document=101, field=2, value_text="SR-2023-01")
ref("documents.customfieldinstance", 3, document=102, field=1, value_monetary="EUR79.90")
ref("documents.customfieldinstance", 4, document=102, field=3, value_date="2023-03-15")
ref("documents.customfieldinstance", 5, document=105, field=1, value_monetary="250.00")

files["manifest.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")


def write():
    for rel, data in files.items():
        p = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)


def check():
    bad = 0
    for rel, data in files.items():
        p = os.path.join(OUT, rel)
        if not os.path.exists(p) or open(p, "rb").read() != data:
            print("abweichend:", rel)
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    check() if "--check" in sys.argv else write()
