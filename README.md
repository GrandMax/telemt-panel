# MTPannel + MTProxy (Fake TLS) + Traefik

> Автор не является владельцем или поставщиком VPN/Proxy-конфигураций. Данный материал не является рекламой VPN/Proxy и предназначен исключительно в информационных целях, только для граждан тех стран, где использование такой информации легально (в том числе в научных и образовательных целях). Автор не имеет намерений побуждать, поощрять или оправдывать использование VPN/Proxy. Отказ от ответственности: автор не несёт ответственности за действия третьих лиц и не поощряет противоправное использование технологий. Используйте прокси и VPN только в соответствии с местным законодательством и исключительно в законных целях — например, для обеспечения безопасности в сети и защищённого удалённого доступа; не применяйте данную технологию для обхода блокировок или иных противоправных действий.

Один порт **443**: по SNI трафик к домену маскировки (например `1c.ru`) уходит в MTProxy, остальное можно отдавать другим сервисам через Traefik.

- **Telemt** — современный MTProxy (Rust, distroless), поддерживает Fake TLS.
- **Traefik** — маршрутизация TCP по SNI с TLS passthrough.

## Установка на сервере (всё с GitHub)

```bash
curl -sSL https://raw.githubusercontent.com/GrandMax/telemt-pannel/main/install.sh | bash
```

или с интерактивным меню и псевдографикой:

```bash
curl -sSL https://raw.githubusercontent.com/GrandMax/telemt-pannel/main/mtpannel.sh | bash
```

Скрипт установит Docker (если нужно), создаст каталог установки, скачает или соберёт образ telemt, настроит Traefik и выведет ссылку вида `tg://proxy?server=...&port=443&secret=...` — добавьте её в Telegram (Настройки → Данные и память → Использовать прокси).

- Каталог установки по умолчанию: `./mtpannel-data`. Другой: `INSTALL_DIR=/opt/mtpannel curl -sSL ... | bash`.
- Домен маскировки по умолчанию задаётся в скрипте (например `pikabu.ru`). Без TTY: `FAKE_DOMAIN=1c.ru curl -sSL ... | bash`.

## Локальный запуск (клонирование репозитория)

После `git clone https://github.com/GrandMax/telemt-pannel.git && cd telemt-pannel` запустите `./install.sh` или `./mtpannel.sh`. Скрипт по умолчанию использует шаблоны из текущего каталога. При выборе «Собрать из исходников» скрипт при необходимости сам проверит наличие репозитория, установит зависимости (Docker, git) и при отсутствии нужных файлов клонирует [GrandMax/telemt-pannel](https://github.com/GrandMax/telemt-pannel) во внутренний каталог установки. Либо настройте вручную и поднимите без скрипта:

1. Сгенерируйте секрет: `openssl rand -hex 16`. Скопируйте `install/telemt.toml.example` в каталог установки как `telemt.toml`, подставьте секрет и домен в `tls_domain`.
2. В `traefik/dynamic/tcp.yml` домен в `HostSNI(...)` должен совпадать с `tls_domain` в `telemt.toml`.
3. Запуск: `docker compose up -d`.
4. Ссылка: `tg://proxy?server=ВАШ_IP&port=443&secret=ВАШ_СЕКРЕТ`.

## Удаление

Скриптом (из каталога с репозиторием или скачав скрипт):

```bash
curl -sSL https://raw.githubusercontent.com/GrandMax/telemt-pannel/main/install.sh | bash -s uninstall
```

Каталог по умолчанию — `./mtpannel-data`. Другой каталог или без подтверждения: `./install.sh uninstall -y /path/to/mtpannel-data`.

Пошагово без скрипта: перейдите в каталог установки, выполните `docker compose down`, затем удалите каталог (конфиги и секрет).

## Структура после установки

```text
mtpannel-data/
├── docker-compose.yml
├── telemt.toml
└── traefik/
    ├── dynamic/
    │   └── tcp.yml    # маршрут по SNI → telemt:1234
    └── static/
```

## Полезные команды

- Логи: `cd mtpannel-data && docker compose logs -f`
- Остановка: `docker compose down`
- Перезапуск после смены конфига: `docker compose up -d --force-recreate`
- После рестарта сервера контейнеры поднимутся сами (`restart: unless-stopped`). Включите Docker при загрузке: `sudo systemctl enable docker`.

## Безопасность

- Ссылку прокси не публикуйте.
- Рекомендуется порт 443 и домен маскировки с рабочим HTTPS (1c.ru, sberbank.ru и т.п.).
- Регулярно обновляйте образы: `docker compose pull && docker compose up -d`.

## Устранение проблем

- **Не подключается к прокси:** проверьте, что контейнеры запущены (`docker compose ps`), порт 443 слушается (`ss -tlnp | grep 443`), файрвол и облачные группы доступа открывают TCP 443, IP в ссылке совпадает с сервером (`curl -s ifconfig.me`), домен маскировки одинаков в `telemt.toml` и в `traefik/dynamic/tcp.yml`.
- **`Error while peeking client hello bytes`** в логах Traefik — обычно health check или сканеры; на работу прокси не влияет.

Подробная документация по установке, переменным окружения и подкомандам: [docs/install.md](docs/install.md).

---

Проект основан на [Telemt — MTProxy on Rust + Tokio](https://github.com/telemt/telemt).
