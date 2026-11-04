FROM alpine:3.22
RUN apk add --no-cache strongswan xl2tpd ppp-daemon dante-server iproute2
COPY entrypoint.sh /entrypoint.sh
# Windows checkouts may add CRLF, which breaks the shebang
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh
EXPOSE 1080
ENTRYPOINT ["/entrypoint.sh"]
