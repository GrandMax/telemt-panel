Примеры запуска:
Оба образа, текущая платформа, логин по переменным:
  DOCKERHUB_USERNAME=grandmax DOCKERHUB_TOKEN=ваш_токен ./scripts/docker-build-push.sh
Оба образа для amd64 и arm64 (через buildx):
  DOCKERHUB_USERNAME=grandmax DOCKERHUB_TOKEN=... ./scripts/docker-build-push.sh --multiarch
Только панель:
  ./scripts/docker-build-push.sh --panel-only
Только telemt:
  ./scripts/docker-build-push.sh --telemt-only

Локальная сборка и запуск с панелью (traefik + telemt + panel):
В каталоге temp/ подготовлены .env, docker-compose.yml и traefik/dynamic/tcp.yml. Запуск из корня репозитория:
  cd temp && docker-compose up --build -d
Панель: http://localhost:8080, прокси: порт 443. После изменений кода: docker-compose up --build -d.

Первый администратор панели (при ручной настройке) создаётся вручную:
  docker exec -it mtpanel-panel python -m app.cli create-admin --username admin --password "ВАШ_ПАРОЛЬ" --sudo
После этого входите в панель по логину admin и указанному паролю.

Параметр пользователя «Max unique IPs» (макс. уникальных IP): лимит одновременно подключённых уникальных IP-адресов для этого пользователя. Задаётся в панели, записывается в конфиг telemt в секцию [access.user_max_unique_ips]. При новом подключении с нового IP, если у пользователя уже подключено столько разных IP, сколько задано лимитом, соединение отклоняется; при отключении клиента соответствующий IP перестаёт учитываться.

### Bad connections на дашборде: как смотреть логи и с чем связаны

Счётчик **Bad connections** на дашборде берётся из метрики telemt `telemt_connections_bad_total`: это соединения, принятые прокси, но отклонённые на этапе handshake (до начала проксирования трафика).

**Как посмотреть логи telemt (из каталога установки, где лежит docker-compose):**

- Все сервисы: `docker compose logs -f`
- Только telemt: `docker compose logs -f telemt`
- Последние 200 строк telemt: `docker compose logs --tail=200 telemt`

Имя контейнера может быть другим (например `mtpannel-telemt`); тогда: `docker logs -f mtpannel-telemt` или `docker compose logs -f telemt` по имени сервиса в compose.

**Что увеличивает Bad connections (и какие сообщения искать в логах):**

| Причина | Уровень лога | Пример сообщения |
|--------|---------------|-------------------|
| Неверный или устаревший PROXY protocol (если включён) | WARN | `Invalid PROXY protocol header` |
| Слишком короткий TLS handshake (< 512 байт) | DEBUG | `TLS handshake too short` |
| Невалидный TLS (не совпал секрет, время и т.д.) | DEBUG | `TLS handshake validation failed` или `HandshakeResult::BadClient` после TLS |
| Replay TLS (повторное использование того же digest) | WARN | `TLS replay attack detected` |
| TLS ок, но невалидный MTProto handshake | DEBUG | `Valid TLS but invalid MTProto handshake` |
| Replay MTProto | WARN | `MTProto replay attack detected` |
| Неверный/устаревший секрет или не найден пользователь (classic/secure) | DEBUG | `MTProto handshake: no matching user found` или `handshake validation failed` |
| Подключение без TLS при выключенных classic/secure режимах | DEBUG | `Non-TLS modes disabled` |

По умолчанию в контейнере стоит `RUST_LOG=info`, поэтому часть причин видна только как общий отказ; для детальной диагностики можно временно задать `RUST_LOG=debug` в `environment` сервиса telemt в docker-compose и перезапустить контейнер — тогда в логах появятся сообщения уровня DEBUG (в т.ч. «TLS handshake too short», «no matching user found», «Non-TLS modes disabled»).
