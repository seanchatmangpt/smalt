FROM mcr.microsoft.com/playwright:v1.56.0-jammy

# The substrate's own CA — the trust chain the production parsers accept
# (P09: certificate distribution is an implementation detail; the browser
# in this image trusts ONLY the smalt dev CA, no bypass flags anywhere).
COPY ca-cert.pem /usr/local/share/ca-certificates/smalt-ca.crt
RUN update-ca-certificates && npm i -g playwright@1.56.0 openid-client@6 --no-audit --no-fund

# Deterministic workdir; scenario scripts mount in via ConfigMap.
WORKDIR /court
