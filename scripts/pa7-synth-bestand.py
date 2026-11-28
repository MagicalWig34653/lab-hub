#!/usr/bin/env python3
"""WP-PA7: erzeugt einen großen synthetischen Bestand über die echte Upload-Route des Hubs.

Nur erfundene Daten: jede Datei beginnt mit `%PDF-1.7` (der Hub erkennt den Typ am Dateianfang), danach folgen Zufallsbytes
(nicht komprimierbar wie echte Scans) und eine laufende Nummer, damit kein Inhalt doppelt vorkommt. Keine echten Dokumente,
keine Namen, keine Texte. Läuft ohne zusätzliche Pakete (nur Standardbibliothek): `python3 -I scripts/pa7-synth-bestand.py ...`.

Aufruf:
  scripts/pa7-synth-bestand.py --base-url http://127.0.0.1:8080 --tenant <uuid> --token-env E2E_SESSION \
      --mix 8000:200K,800:2M,50:16M --prefix lauf1 [--threads 6]

  --mix        kommagetrennt `Anzahl:Größe` (Größe mit K oder M, ungefähr: jede Datei ±25 % davon)
  --token-env  Name der Umgebungsvariable mit dem Sitzungstoken (nie als Argument, damit es nicht im Prozessverzeichnis steht)
  --prefix     Teil des Dateinamens und der Zufallsbasis; zwei Läufe mit verschiedenem Präfix erzeugen verschiedene Dateien

Ausgabe (stdout, eine Zeile JSON): documents, bytes, seconds, docs_per_s, mib_per_s, failed.
Endet mit Exit-Code 1, wenn ein Upload fehlschlug.
"""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
import random
import sys
import time
import urllib.parse
import uuid


def parse_size(text):
    text = text.strip().upper()
    mult = {"K": 1024, "M": 1024 * 1024}.get(text[-1:], None)
    if mult is None:
        raise ValueError("Größe braucht K oder M: " + text)
    return int(float(text[:-1]) * mult)


def parse_mix(text):
    plan = []
    for part in text.split(","):
        count, size = part.split(":")
        plan.append((int(count), parse_size(size)))
    return plan


def make_pdf(prefix, index, size, rng):
    # Zufallsbytes aus dem Betriebssystem: nicht komprimierbar, nie zweimal gleich
    head = ("%PDF-1.7\n%synthetic " + prefix + " " + str(index) + "\n").encode()
    body = os.urandom(max(size - len(head) - 8, 16))
    return head + body + b"\n%%EOF\n"


def upload(base, tenant, token, name, data):
    url = urllib.parse.urlsplit(base)
    cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    conn = cls(url.hostname, url.port, timeout=300)
    path = "/api/v1/tenants/%s/dms/uploads?filename=%s" % (tenant, urllib.parse.quote(name))
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/octet-stream",
        "Idempotency-Key": str(uuid.uuid4()),
        "Accept": "application/json",
    }
    try:
        conn.request("POST", path, body=data, headers=headers)
        resp = conn.getresponse()
        body = resp.read()
        return resp.status, body[:200]
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--token-env", default="E2E_SESSION")
    ap.add_argument("--mix", required=True)
    ap.add_argument("--prefix", default="synth")
    ap.add_argument("--threads", type=int, default=6)
    args = ap.parse_args()
    token = os.environ.get(args.token_env, "")
    if not token:
        print("FEHLER: Umgebungsvariable %s ist leer" % args.token_env, file=sys.stderr)
        return 2
    rng = random.Random(args.prefix)
    jobs = []
    n = 0
    for count, size in parse_mix(args.mix):
        for _ in range(count):
            n += 1
            jobs.append((n, int(size * rng.uniform(0.75, 1.25))))
    rng.shuffle(jobs)

    sent = 0
    failed = 0
    started = time.monotonic()

    def work(job):
        index, size = job
        data = make_pdf(args.prefix, index, size, rng)
        status, body = upload(args.base_url, args.tenant, token, "%s-%06d.pdf" % (args.prefix, index), data)
        return index, len(data), status, body

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as pool:
        for i, (index, size, status, body) in enumerate(pool.map(work, jobs), 1):
            if status in (200, 201, 202):
                sent += size
            else:
                failed += 1
                print("FEHLER: Datei %d: Status %d %s" % (index, status, body.decode("utf-8", "replace")), file=sys.stderr)
            if i % 500 == 0:
                print("  %d/%d hochgeladen, %.1f MiB, %.0f s" % (i, len(jobs), sent / 1048576, time.monotonic() - started), file=sys.stderr)
    seconds = time.monotonic() - started
    ok = len(jobs) - failed
    print(json.dumps({
        "documents": ok, "bytes": sent, "seconds": round(seconds, 1),
        "docs_per_s": round(ok / seconds, 1) if seconds else 0,
        "mib_per_s": round(sent / 1048576 / seconds, 1) if seconds else 0, "failed": failed,
    }))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
