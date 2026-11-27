#!/usr/bin/env python3
"""WP-PA1: befüllt eine LOKALE paperless-ngx-Instanz (Container, Port nur auf 127.0.0.1) mit ERFUNDENEN Dokumenten über deren REST-API.
Nur Standardbibliothek. Keine echten Daten, kein Code und keine Texte aus Paperless-ngx (GPL-3.0): die Dokumente entstehen hier (eigener PDF-/PNG-Erzeuger),
Paperless wird nur über seine öffentliche API bedient. Ausgabe auf stdout: JSON mit den erwarteten Zahlen und den (synthetischen, nur lokal gültigen) Tokens.

Aufruf:  PA_URL=http://127.0.0.1:18000 PA_ADMIN=<benutzer> PA_PASS=<kennwort> python3 seed.py
"""
import base64
import hashlib
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib

URL = os.environ.get("PA_URL", "http://127.0.0.1:18000").rstrip("/")
ADMIN = os.environ["PA_ADMIN"]
PASSWORD = os.environ["PA_PASS"]
READER = "pa1reader"
NOPERM = "pa1noperm"
READER_PASSWORD = os.environ.get("PA_READER_PASS", "pa1-reader-synthetic-pw")
AUTH = "Basic " + base64.b64encode(f"{ADMIN}:{PASSWORD}".encode()).decode()


def call(method, path, body=None, headers=None, raw=False, auth=None):
    h = {"Authorization": auth or AUTH, "Accept": "application/json; version=10"}
    data = None
    if isinstance(body, (dict, list)):
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    elif body is not None:
        data = body
    h.update(headers or {})
    req = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            payload = r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: HTTP {e.code} {e.read()[:300]!r}")
    return payload if raw else (json.loads(payload) if payload else None)


def multipart(fields, filename, content, content_type):
    boundary = "----pa1seed" + hashlib.sha256(filename.encode()).hexdigest()[:16]
    out = b""
    for k, vals in fields.items():
        for v in (vals if isinstance(vals, list) else [vals]):
            out += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    out += f'--{boundary}\r\nContent-Disposition: form-data; name="document"; filename="{filename}"\r\nContent-Type: {content_type}\r\n\r\n'.encode() + content + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return out, {"Content-Type": f"multipart/form-data; boundary={boundary}"}


def pdf(lines, seed):
    """Minimales gültiges PDF mit Textschicht (eine Seite, Helvetica); `seed` macht jede Datei einzigartig."""
    esc = lambda t: t.replace("\\", "/").replace("(", "[").replace(")", "]")
    stream = "BT /F1 12 Tf 72 720 Td 14 TL " + " T* ".join(f"({esc(t)}) Tj" for t in lines) + " ET"
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream), "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    body = "%PDF-1.4\n% synthetic pa1 " + seed + "\n"
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(body))
        body += "%d 0 obj\n%s\nendobj\n" % (i, o)
    xref = len(body)
    body += "xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + "".join("%010d 00000 n \n" % o for o in offsets)
    body += "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return body.encode("latin-1")


def png(seed, size=64):
    h = hashlib.sha256(seed.encode()).digest()
    rows = b"".join(b"\x00" + bytes(255 if (x // 8 + y // 8) % 2 else h[(x + y) % 32] // 4 for x in range(size)) for y in range(size))
    chunk = lambda tag, d: struct.pack(">I", len(d)) + tag + d + struct.pack(">I", zlib.crc32(tag + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 0, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def wait_task(task_id, document=True):
    for _ in range(180):
        r = call("GET", f"/api/tasks/?task_id={task_id}")
        r = r if isinstance(r, list) else r.get("results", [])
        if r and r[0]["status"].lower() in ("success", "failure"):
            if r[0]["status"].lower() != "success":
                sys.exit(f"Aufnahme fehlgeschlagen: {r[0].get('result_data')}")
            return int((r[0].get("result_data") or {})["document_id"]) if document else None
        time.sleep(2)
    sys.exit("Aufnahme dauert zu lange")


def make(kind, name, **extra):
    return call("POST", f"/api/{kind}/", {"name": name, "matching_algorithm": 0, **extra})["id"]


def main():
    out = {"docs": {}}
    # Referenzdaten (alle erfunden). Eine private Korrespondentin gehört nur dem Administrator (der Lese-Benutzer sieht sie nicht).
    corr = {n: make("correspondents", n) for n in ("Beispiel Strom AG", "Muster Versicherung", "Erfunden GmbH", "Privat Absender")}
    types = {n: make("document_types", n) for n in ("Rechnung", "Vertrag", "Notiz")}
    tags = {n: make("tags", n, color="#3b82f6") for n in ("inbox", "steuer", "jahr-2026", "größe")}
    path_id = call("POST", "/api/storage_paths/", {"name": "Nach Jahr", "path": "{{ created_year }}/{{ correspondent }}/{{ title }}", "matching_algorithm": 0})["id"]
    cf = {}
    for name, dtype, extra in (("Betrag", "monetary", {}), ("Fällig am", "date", {}), ("Vertragsnummer", "string", {}), ("Bezahlt", "boolean", {}),
                               ("Anzahl", "integer", {}), ("Kategorie", "select", {"extra_data": {"select_options": [{"id": "a1", "label": "Haushalt"}, {"id": "a2", "label": "Arbeit"}]}})):
        cf[name] = call("POST", "/api/custom_fields/", {"name": name, "data_type": dtype, **extra})["id"]
    # Nur-Lese-Benutzer (PA1-4): Leserechte auf Dokumente und Stammdaten, nichts sonst
    perms = [f"view_{m}" for m in ("document", "correspondent", "documenttype", "tag", "storagepath", "customfield", "note")]
    reader = call("POST", "/api/users/", {"username": READER, "password": READER_PASSWORD, "user_permissions": perms, "is_active": True, "is_staff": False, "is_superuser": False})
    # Benutzer ohne jedes Recht: die API antwortet mit 403 (nicht 401)
    call("POST", "/api/users/", {"username": NOPERM, "password": READER_PASSWORD, "user_permissions": [], "is_active": True, "is_staff": False, "is_superuser": False})

    spec = [
        # key, Titel, Zeilen, Korrespondent, Typ, Tags, ASN, Datum, privat, Felder, Notizen
        ("strom1", "Stromrechnung Januar", ["Stromrechnung Januar 2026", "Kundennummer 4711", "Betrag 89,50 EUR"], "Beispiel Strom AG", "Rechnung", ["steuer", "jahr-2026"], 101, "2026-01-15", False,
         [("Betrag", "EUR89.50"), ("Fällig am", "2026-02-01"), ("Bezahlt", True)], []),
        ("strom2", "Stromrechnung Februar", ["Stromrechnung Februar 2026", "Kundennummer 4711", "Betrag 91,20 EUR"], "Beispiel Strom AG", "Rechnung", ["steuer", "jahr-2026"], 102, "2026-02-14", False,
         [("Betrag", "EUR91.20"), ("Anzahl", 3)], ["Abbuchung geprüft"]),
        ("police", "Versicherungspolice Hausrat", ["Hausratversicherung Police", "Versicherungsnummer HR-2026-0042"], "Muster Versicherung", "Vertrag", ["jahr-2026"], None, "2026-01-02", False,
         [("Vertragsnummer", "HR-2026-0042"), ("Kategorie", "a1")], ["Kündigung bis 30.09.", "Beitrag jährlich"]),
        ("miet", "Mietvertrag Beispielweg", ["Mietvertrag Beispielweg 12", "Beginn 01.03.2026"], None, "Vertrag", [], 103, "2025-12-20", False, [], []),
        ("bon", "Kassenbon Baumarkt", ["Kassenbon Baumarkt", "Summe 23,99 EUR"], None, None, ["inbox"], None, "2026-03-03", False, [("Kategorie", "a2")], []),
        ("umlaut", "Übersicht Größe ß Ärger", ["Übersicht Größe", "Ärger mit Umlauten"], "Erfunden GmbH", "Notiz", ["größe"], 104, "2026-04-01", False, [], []),
        ("version", "Rechnung Erfunden GmbH", ["Rechnung Erfunden GmbH", "Fassung eins"], "Erfunden GmbH", "Rechnung", ["steuer"], 105, "2026-05-05", False, [("Betrag", "EUR10.00")], []),
        ("privat", "Privates Dokument", ["Nur für den Administrator", "nicht freigegeben"], "Privat Absender", "Notiz", [], None, "2026-06-06", True, [], []),
        ("pfad", "Dokument mit Speicherpfad", ["Dokument mit Speicherpfad", "Ablage nach Jahr"], "Muster Versicherung", "Rechnung", ["jahr-2026"], None, "2026-07-07", False, [], []),
    ]
    ids = {}
    for key, title, lines, c, t, tg, asn, created, private, fields, notes in spec:
        f = {"title": title, "created": created}
        if c: f["correspondent"] = corr[c]
        if t: f["document_type"] = types[t]
        if tg: f["tags"] = [tags[x] for x in tg]
        if asn: f["archive_serial_number"] = asn
        if key == "pfad": f["storage_path"] = path_id
        body, h = multipart(f, f"{key}.pdf", pdf(lines, key), "application/pdf")
        ids[key] = wait_task(call("POST", "/api/documents/post_document/", body, h))
    # ein Scan als Bild (Paperless macht daraus ein Archiv-PDF)
    body, h = multipart({"title": "Scan Bild", "created": "2026-08-08"}, "scan.png", png("scan"), "image/png")
    ids["bild"] = wait_task(call("POST", "/api/documents/post_document/", body, h))
    # zweite Fassung (neuere Paperless-Stände): gleiche Dokument-ID, neue Datei
    body, h = multipart({"version_label": "Fassung zwei"}, "version2.pdf", pdf(["Rechnung Erfunden GmbH", "Fassung zwei"], "version-two"), "application/pdf")
    wait_task(call("POST", f"/api/documents/{ids['version']}/update_version/", body, h), document=False)   # die Fassung entsteht asynchron: ohne Warten zaehlt noch die alte
    # Felder, Notizen, Besitz: alles ohne Besitzer sichtbar für Benutzer mit Leserecht, `privat` nur für den Administrator
    for key, title, lines, c, t, tg, asn, created, private, fields, notes in spec:
        patch = {"custom_fields": [{"field": cf[n], "value": v} for n, v in fields]}
        patch["owner"] = ADMIN_ID(ids, private)
        call("PATCH", f"/api/documents/{ids[key]}/", patch)
        for n in notes:
            call("POST", f"/api/documents/{ids[key]}/notes/", {"note": n})
    # ein Dokument im Papierkorb der Instanz: die API listet es nicht; es darf auch aus dem Export nicht importiert werden
    body, h = multipart({"title": "Im Papierkorb", "created": "2026-09-09"}, "papierkorb.pdf", pdf(["Dieses Dokument liegt im Papierkorb"], "trash"), "application/pdf")
    trashed = wait_task(call("POST", "/api/documents/post_document/", body, h))
    call("DELETE", f"/api/documents/{trashed}/", raw=True)
    out["trashed"] = trashed
    out["docs"] = ids
    out["reader"] = {"username": READER}
    out["reader_token"] = call("POST", "/api/token/", json.dumps({"username": READER, "password": READER_PASSWORD}).encode(), {"Content-Type": "application/json"}, auth="none")["token"]
    out["noperm_token"] = call("POST", "/api/token/", json.dumps({"username": NOPERM, "password": READER_PASSWORD}).encode(), {"Content-Type": "application/json"}, auth="none")["token"]
    out["admin_token"] = call("POST", "/api/token/", json.dumps({"username": ADMIN, "password": PASSWORD}).encode(), {"Content-Type": "application/json"}, auth="none")["token"]
    print(json.dumps(out, indent=1))


_admin = {}
def ADMIN_ID(ids, private):
    if "id" not in _admin:
        _admin["id"] = [u["id"] for u in call("GET", "/api/users/")["results"] if u["username"] == ADMIN][0]
    return _admin["id"] if private else None


if __name__ == "__main__":
    main()
