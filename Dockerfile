# Aethrion's HTTP server (and its RisuAI/SillyTavern bridge) without
# installing Elixir. OTP 29 answers the browser's preflight (OPTIONS) that
# older :httpd refuses, so a browser-based chat app can reach it too.
FROM elixir:1.20-otp-29-slim

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    HOME=/app

WORKDIR /app

# CA certificates for Hex at build time and for model APIs over HTTPS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --home-dir /app --shell /usr/sbin/nologin aethrion \
    && mkdir -p /data \
    && chown aethrion /app /data

USER aethrion

RUN mix local.hex --force && mix local.rebar --force

COPY --chown=aethrion mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY --chown=aethrion lib lib
COPY --chown=aethrion priv priv
RUN mix compile

VOLUME /data
EXPOSE 4848

# Listens on every address inside the container; publish the port to
# 127.0.0.1 (as compose.yaml does) or set AETHRION_TOKEN.
ENTRYPOINT ["mix", "aethrion.serve", "--bind", "0.0.0.0", "--data", "/data"]
CMD ["--cast", "priv/casts/campfire.json", "--locale", "ko"]
