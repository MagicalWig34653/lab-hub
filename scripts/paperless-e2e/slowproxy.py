#!/usr/bin/env python3
"""WP-PA3V: TCP-Weiterleitung 127.0.0.1:<Port> -> 127.0.0.1:<Ziel-Port> (nur Standardbibliothek), die die Antworten ab dem ersten MiB je Verbindung auf eine feste
Rate bremst (Bytes pro Sekunde): eine langsame Leitung zu einer lokalen Instanz, damit der Download einer großen Datei sicher länger dauert als die Anfragefrist des Hub.
Die Daten kommen laufend (kein Stillstand), nur langsam. Keine Zugangsdaten, nichts wird protokolliert.

Aufruf:  python3 slowproxy.py <Port> <Ziel-Port> <Bytes pro Sekunde>
"""
import asyncio
import sys

FAST_BYTES = 1024 * 1024
CHUNK = 16 * 1024


async def pump(reader, writer, rate=None):
    sent = 0
    try:
        while data := await reader.read(CHUNK):
            writer.write(data)
            await writer.drain()
            sent += len(data)
            if rate and sent > FAST_BYTES:
                await asyncio.sleep(len(data) / rate)
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_r, client_w, target, rate):
    try:
        up_r, up_w = await asyncio.open_connection("127.0.0.1", target)
    except OSError:
        client_w.close()
        return
    await asyncio.gather(pump(client_r, up_w), pump(up_r, client_w, rate))


async def main(port, target, rate):
    server = await asyncio.start_server(lambda r, w: handle(r, w, target, rate), "127.0.0.1", port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])))
