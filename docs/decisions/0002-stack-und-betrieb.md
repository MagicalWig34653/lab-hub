# ADR 0002: Stack, Betrieb, Lizenz

Status: entschieden (Nutzer, 28.10.2026).

- Backend Swift (Vapor, Fluent), Vorbild `timetrack-backend`: REST/JSON mit OpenAPI-Vertrag, MCP als Adapter, Passkey/OIDC, Modul-Registry.
- Frontend SvelteKit + shadcn-svelte als PWA, statisch vom Backend ausgeliefert, Vorbild `timetrack-pwa`.
- Selbst hostbar per Docker Compose; ein Stack und eine Datenbank je Kunde.
- Lizenz AGPL-3.0-only, Open Source. Offener Lizenzbefund aus `timetrack-backend` (BoringSSL in swift-nio-ssl) vor Veröffentlichung klären.
- Umbenennung: Bundle-IDs und Container der Apps werden bei Bedarf geändert, Daten vorher exportieren und importieren.
