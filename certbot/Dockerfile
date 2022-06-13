FROM certbot/certbot

VOLUME /certs
VOLUME /etc/letsencrypt
EXPOSE 80

RUN apk update && \
	apk add openssl curl

COPY ./scripts/ /scripts
RUN chmod -R +x /scripts/

ADD crontab /etc/crontabs
RUN crontab /etc/crontabs/crontab

ENTRYPOINT ["/scripts/entrypoint.sh"]
