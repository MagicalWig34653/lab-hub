# Mehrstufiges Image (Entwurf): baut das Backend und startet es mit read-only Root; Entrypoint liest <NAME>_FILE-Secrets.
FROM swift:6.0-jammy AS build
WORKDIR /src
COPY backend/ ./
RUN swift build -c release --product App --static-swift-stdlib
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libcurl4 tzdata && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home labhub
COPY --from=build /src/.build/release/App /usr/local/bin/lab-hub
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
USER labhub
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
