FROM scratch

ARG REVISION

LABEL org.opencontainers.image.source="https://github.com/xxh3898/Portfolio"
LABEL org.opencontainers.image.revision="${REVISION}"
LABEL io.chochiho.runtime-config.project="portfolio"

COPY homeserver/compose.yaml /runtime/compose.yaml

CMD ["/runtime/compose.yaml"]
