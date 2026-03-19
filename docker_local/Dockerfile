FROM docker:28-dind

WORKDIR /app

COPY docker-compose/docker-compose.yml /app/docker-compose/compose.yml
COPY docker-compose/.env /app/docker-compose/.env

COPY docker-compose/clickhouse_config /app/docker-compose/clickhouse_config
COPY docker-compose/configVault /app/docker-compose/configVault
COPY docker-compose/keycloak-themes /app/docker-compose/keycloak-themes
COPY docker-compose/importsKeyCloak /app/docker-compose/importsKeyCloak
COPY docker-compose/nginx /app/docker-compose/nginx
COPY docker-compose/postgresConfig /app/docker-compose/postgresConfig
COPY docker-compose/scripts /app/docker-compose/scripts

COPY docker_local/start.sh /app/start.sh
RUN chmod +x /app/start.sh

EXPOSE 443

ENTRYPOINT ["/app/start.sh"]
