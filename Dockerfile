# Mehrstufiges Image: baut die PWA (WP-H9) und das Backend; das Backend liefert die PWA statisch aus (PWA_DIR).
# Read-only Root: Die PWA liegt fest im Image unter /usr/share/lab-hub/pwa, zur Laufzeit wird nichts geschrieben.
# Entrypoint liest <NAME>_FILE-Secrets.
FROM node:24-bookworm-slim AS pwa
ARG BUILD_REVISION=unknown
ENV BUILD_REVISION=${BUILD_REVISION}
WORKDIR /src/pwa
COPY pwa/package.json pwa/package-lock.json ./
RUN npm ci
COPY pwa/ ./
RUN npm run build

FROM swift:6.2-jammy AS build
WORKDIR /src
COPY backend/ ./
RUN swift build -c release --product App --static-swift-stdlib
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libcurl4 tzdata && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home labhub
COPY --from=build /src/.build/release/App /usr/local/bin/lab-hub
COPY --from=pwa /src/pwa/build /usr/share/lab-hub/pwa
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENV PWA_DIR=/usr/share/lab-hub/pwa
USER labhub
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
