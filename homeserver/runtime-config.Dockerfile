FROM scratch

ARG REVISION

LABEL org.opencontainers.image.source="https://github.com/xxh3898/Portfolio"
LABEL org.opencontainers.image.revision="${REVISION}"
LABEL io.chochiho.runtime-config.project="portfolio"

COPY homeserver/compose.yaml /runtime/compose.yaml
COPY --chmod=0700 homeserver/scripts/deploy-portfolio.sh /runtime/scripts/deploy-portfolio.sh

CMD ["/runtime/compose.yaml"]
