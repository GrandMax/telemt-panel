#!/usr/bin/env bash
# MTpannel installer: fully interactive menu when run with no args (TTY).
# Uses local templates from install/; builds telemt from repo Dockerfile.
# Non-interactive: pass action as first arg and use env vars (INSTALL_DIR, LISTEN_PORT, FAKE_DOMAIN, etc.).

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/mtpannel-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-pikabu.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"
LISTEN_PORT="${LISTEN_PORT:-443}"
TELEMT_PREBUILT_IMAGE="${TELEMT_PREBUILT_IMAGE:-grandmax/telemt:latest}"
TELEMT_IMAGE_SOURCE="${TELEMT_IMAGE_SOURCE:-prebuilt}"
PANEL_PREBUILT_IMAGE="${PANEL_PREBUILT_IMAGE:-grandmax/telemt-panel:latest}"
SCRIPT_VERSION="1.0.4"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()   { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# Resolve install dir to absolute path (safe with set -e).
resolve_install_dir() {
	local d="$1"
	case "$d" in
		/*) echo "$d" ;;
		*) echo "$(pwd)/${d}" ;;
	esac
}

rerun_cmd() {
	if [[ "$0" == *bash* ]] || [[ "$0" == -* ]]; then
		echo "bash ${REPO_ROOT}/install.sh"
	else
		echo "bash ${REPO_ROOT}/install.sh"
	fi
}

check_docker() {
	if command -v docker &>/dev/null; then
		if docker info &>/dev/null 2>&1; then
			info "Docker доступен."
			return 0
		fi
		echo ""
		warn "Docker установлен, но текущий пользователь не в группе docker."
		echo ""
		echo "Выполните команду (добавление в группу и применение):"
		echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo ""
		echo "Затем запустите этот скрипт снова:"
		echo -e "  ${GREEN}$(rerun_cmd)${NC}"
		echo ""
		exit 1
	fi
	info "Установка Docker..."
	curl -fsSL https://get.docker.com | sh
	if ! docker info &>/dev/null 2>&1; then
		echo ""
		warn "Docker установлен. Нужно добавить пользователя в группу docker."
		echo ""
		echo "Выполните команду:"
		echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo ""
		echo "Затем запустите этот скрипт снова:"
		echo -e "  ${GREEN}$(rerun_cmd)${NC}"
		echo ""
		exit 1
	fi
}

is_port_in_use() {
	local port="$1"
	if command -v ss &>/dev/null; then
		ss -tuln 2>/dev/null | grep -qE "[.:]${port}[[:space:]]"
		return $?
	fi
	if command -v nc &>/dev/null; then
		nc -z 127.0.0.1 "$port" 2>/dev/null
		return $?
	fi
	return 1
}

# Returns 0 if dir looks like repo root for build (has install/ and Dockerfile).
is_build_repo_root() {
	local dir="${1:-}"
	[[ -f "${dir}/install/docker-compose.yml" ]] && \
	[[ -f "${dir}/install/telemt.toml.example" ]] && \
	[[ -f "${dir}/install/traefik-dynamic-tcp.yml" ]] && \
	[[ -f "${dir}/Dockerfile" ]]
}

# Ensure git is available; try to install on common distros. Exit 1 if not available.
ensure_git() {
	if command -v git &>/dev/null; then
		return 0
	fi
	info "Для сборки из исходников нужен git. Попытка установки..."
	if command -v apt-get &>/dev/null; then
		if apt-get update &>/dev/null && apt-get install -y git &>/dev/null; then
			info "git установлен."
			return 0
		fi
	fi
	if command -v dnf &>/dev/null; then
		if dnf install -y git &>/dev/null; then
			info "git установлен."
			return 0
		fi
	fi
	if command -v yum &>/dev/null; then
		if yum install -y git &>/dev/null; then
			info "git установлен."
			return 0
		fi
	fi
	err "Установите git вручную для варианта «Собрать из исходников» (apt install git / dnf install git / yum install git)."
}

prompt_install_dir() {
	if [[ -n "${INSTALL_DIR_FROM_ENV}" ]]; then
		INSTALL_DIR="${INSTALL_DIR_FROM_ENV}"
		return
	fi
	if [[ -t 0 ]]; then
		local opt_dir="/opt/mtpannel-data"
		local cur_dir
		cur_dir="$(pwd)/mtpannel-data"
		echo "" >&2
		echo "Выберите каталог установки:" >&2
		echo "  1) ${opt_dir}  (рекомендуется)" >&2
		if [[ "$(resolve_install_dir "$cur_dir")" != "$opt_dir" ]]; then
			echo "  2) ${cur_dir}  (текущий каталог)" >&2
			echo "  3) Указать вручную" >&2
			echo "" >&2
			echo -n "Вариант [1]: " >&2
			read -r choice || true
			choice="${choice:-1}"
		else
			echo "  2) Указать вручную" >&2
			echo "" >&2
			echo -n "Вариант [1]: " >&2
			read -r choice || true
			choice="${choice:-1}"
			# Remap: if cur_dir == opt_dir, option 2 means "custom"
			if [[ "$choice" == "2" ]]; then choice="3"; fi
		fi
		case "$choice" in
			1) INSTALL_DIR="$opt_dir" ;;
			2) INSTALL_DIR="$cur_dir" ;;
			3)
				echo -n "Введите путь: " >&2
				read -r input || true
				if [[ -n "$input" ]]; then
					INSTALL_DIR="$input"
				fi
				;;
			*) INSTALL_DIR="$opt_dir" ;;
		esac
	fi
}

prompt_port() {
	local suggested=443
	if is_port_in_use 443; then
		warn "Порт 443 занят."
		suggested=1443
		while true; do
			if [[ -t 0 ]]; then
				echo -n "Введите порт [${suggested}]: " >&2
				read -r input || true
				if [[ -z "$input" ]]; then input=$suggested; fi
			else
				# Non-interactive: respect explicit LISTEN_PORT from env
				if [[ "${LISTEN_PORT:-443}" != "443" ]]; then
					if is_port_in_use "$LISTEN_PORT"; then
						warn "Порт ${LISTEN_PORT} занят. Используется как указано."
					fi
					return
				fi
				LISTEN_PORT=$suggested
				return
			fi
			if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
				if is_port_in_use "$input"; then
					warn "Порт ${input} тоже занят, выберите другой."
				else
					LISTEN_PORT=$input
					return
				fi
			else
				warn "Введите число от 1 до 65535."
			fi
		done
	else
		if [[ -t 0 ]]; then
			echo -n "Порт для прокси [443]: " >&2
			read -r input || true
			if [[ -z "$input" ]]; then input=443; fi
			while true; do
					if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
					if is_port_in_use "$input"; then
						warn "Порт ${input} занят, выберите другой."
						echo -n "Введите порт: " >&2
						read -r input || true
					else
						LISTEN_PORT=$input
						return
					fi
				else
					warn "Введите число от 1 до 65535."
					echo -n "Введите порт [443]: " >&2
					read -r input || true
					if [[ -z "$input" ]]; then input=443; fi
				fi
			done
		else
			# Неинтерактивно: порт 443 свободен — используем 443 или LISTEN_PORT из env
			LISTEN_PORT="${LISTEN_PORT:-443}"
		fi
	fi
}

prompt_fake_domain() {
	if [[ -n "${FAKE_DOMAIN_FROM_ENV}" ]]; then
		FAKE_DOMAIN="${FAKE_DOMAIN_FROM_ENV}"
		return
	fi
	if [[ -t 0 ]]; then
		echo -n "Домен для маскировки Fake TLS (SNI) [${FAKE_DOMAIN}]: " >&2
		read -r input || true
		if [[ -n "$input" ]]; then FAKE_DOMAIN="$input"; fi
	fi
}

confirm_install() {
	if [[ ! -t 0 ]]; then return 0; fi
	echo ""
	echo "Параметры установки:"
	echo "  Каталог: ${INSTALL_DIR}"
	echo "  Порт:    ${LISTEN_PORT}"
	echo "  Домен:   ${FAKE_DOMAIN}"
	echo -n "Продолжить? [Y/n] " >&2
	read -r ans || true
	ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
	if [[ -z "$ans" ]] || [[ "$ans_lower" == "y" ]] || [[ "$ans_lower" == "yes" ]]; then
		return 0
	fi
	info "Установка отменена."
	exit 0
}

# Set TELEMT_IMAGE_SOURCE=build or prebuilt. Interactive: prompt; non-interactive: use env (default prebuilt).
prompt_image_source() {
	if [[ -t 0 ]]; then
		echo ""
		echo "Образы Docker:"
		echo "  1) Скачать готовые образы с Docker Hub (рекомендуется)"
		echo "  2) Собрать из исходников (локально)"
		echo -n "Выбор [1]: " >&2
		read -r input || true
		input="${input%% *}"
		if [[ "$input" == "2" ]]; then
			TELEMT_IMAGE_SOURCE=build
		else
			TELEMT_IMAGE_SOURCE=prebuilt
		fi
	else
		# Non-interactive: already set from env, default prebuilt
		TELEMT_IMAGE_SOURCE="${TELEMT_IMAGE_SOURCE:-prebuilt}"
	fi
}

# Set INSTALL_PANEL=yes or no. Interactive: prompt; non-interactive: use env (default no).
prompt_install_panel() {
	if [[ -t 0 ]]; then
		echo ""
		echo -n "Установить панель управления (веб-интерфейс для пользователей и ссылок)? (y/N): " >&2
		read -r input || true
		input=$(printf '%s' "${input}" | tr '[:upper:]' '[:lower:]')
		if [[ "$input" == "y" ]] || [[ "$input" == "yes" ]] || [[ "$input" == "д" ]]; then
			INSTALL_PANEL=yes
		else
			INSTALL_PANEL=no
		fi
	else
		INSTALL_PANEL="${INSTALL_PANEL:-no}"
	fi
}

generate_secret() {
	openssl rand -hex 16
}

TELEMT_INSTALL_BASE_URL="${TELEMT_INSTALL_BASE_URL:-https://raw.githubusercontent.com/GrandMax/telemt-panel/main/install}"

ensure_install_templates() {
	local required="docker-compose.yml docker-compose.prebuilt.yml docker-compose.panel.yml docker-compose.panel.prebuilt.yml telemt.toml.example traefik-dynamic-tcp.yml"
	local have_all=1
	local f
	for f in $required; do
		if [[ ! -f "${REPO_ROOT}/install/${f}" ]]; then
			have_all=0
			break
		fi
	done
	[[ $have_all -eq 1 ]] && return 0

	if [[ -t 0 ]]; then
		warn "Шаблоны не найдены в ${REPO_ROOT}/install/."
		echo -n "Скачать с GitHub (GrandMax/telemt-panel)? (Y/n): " >&2
		read -r ans || true
		ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
		if [[ "$ans_lower" == "n" ]] || [[ "$ans_lower" == "no" ]]; then
			err "Шаблоны не найдены в ${REPO_ROOT}/install/. Запускайте скрипт из корня репозитория или разрешите загрузку с GitHub."
		fi
	else
		info "Шаблоны не найдены. Пытаюсь скачать с GitHub..."
	fi

	local cache="/opt/mtpannel-templates"
	mkdir -p "${cache}/install"
	for f in $required; do
		if ! curl -sSL -o "${cache}/install/${f}" "${TELEMT_INSTALL_BASE_URL}/${f}"; then
			err "Не удалось скачать шаблон: ${f}"
		fi
	done
	REPO_ROOT="$cache"
	info "Шаблоны загружены в ${REPO_ROOT}/install/"
}

copy_and_configure() {
	ensure_install_templates
	info "Создаю каталоги и копирую шаблоны из ${REPO_ROOT}/install/ ..."
	mkdir -p "${INSTALL_DIR}"
	mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

	if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
		if [[ "$TELEMT_IMAGE_SOURCE" == "prebuilt" ]]; then
			sed -e "s|image: grandmax/telemt:latest|image: ${TELEMT_PREBUILT_IMAGE}|g" \
			    -e "s|image: grandmax/telemt-panel:latest|image: ${PANEL_PREBUILT_IMAGE}|g" \
			    "${REPO_ROOT}/install/docker-compose.panel.prebuilt.yml" > "${INSTALL_DIR}/docker-compose.yml"
		else
			cp "${REPO_ROOT}/install/docker-compose.panel.yml" "${INSTALL_DIR}/docker-compose.yml"
		fi
		PANEL_SECRET_KEY=$(openssl rand -hex 32)
		# .env for panel mode
		{
			echo "REPO_ROOT=${REPO_ROOT}"
			echo "LISTEN_PORT=${LISTEN_PORT}"
			echo "TELEMT_IMAGE_SOURCE=${TELEMT_IMAGE_SOURCE}"
			echo "PANEL_SECRET_KEY=${PANEL_SECRET_KEY}"
			echo "PANEL_PORT=${PANEL_PORT:-8080}"
			echo "PROXY_HOST=${PROXY_HOST:-localhost}"
			echo "FAKE_DOMAIN=${FAKE_DOMAIN}"
		} > "${INSTALL_DIR}/.env"
		info "Режим «прокси + панель». Конфиг прокси будет в volume, панель на порту ${PANEL_PORT:-8080}."
	else
		if [[ "$TELEMT_IMAGE_SOURCE" == "prebuilt" ]]; then
			sed -e "s|image: grandmax/telemt:latest|image: ${TELEMT_PREBUILT_IMAGE}|g" \
				"${REPO_ROOT}/install/docker-compose.prebuilt.yml" > "${INSTALL_DIR}/docker-compose.yml"
		else
			cp "${REPO_ROOT}/install/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
		fi
		cp "${REPO_ROOT}/install/telemt.toml.example" "${INSTALL_DIR}/telemt.toml.example"
		SECRET=$(generate_secret)
		sed -e "s/ПОДСТАВЬТЕ_32_СИМВОЛА_HEX/${SECRET}/g" \
		    -e "s/tls_domain = \"pikabu.ru\"/tls_domain = \"${FAKE_DOMAIN}\"/g" \
		    -e "s/TELEMT_PORT_PLACEHOLDER/${TELEMT_INTERNAL_PORT}/g" \
		    "${INSTALL_DIR}/telemt.toml.example" > "${INSTALL_DIR}/telemt.toml"
		rm -f "${INSTALL_DIR}/telemt.toml.example"
		info "Создан ${INSTALL_DIR}/telemt.toml (домен маскировки: ${FAKE_DOMAIN})"
		printf '%s' "$SECRET" > "${INSTALL_DIR}/.secret"
		{
			echo "REPO_ROOT=${REPO_ROOT}"
			echo "LISTEN_PORT=${LISTEN_PORT}"
			echo "TELEMT_IMAGE_SOURCE=${TELEMT_IMAGE_SOURCE}"
		} > "${INSTALL_DIR}/.env"
	fi

	sed -e "s/SNI_DOMAIN_PLACEHOLDER/${FAKE_DOMAIN}/g" \
	    -e "s/TELEMT_PORT_PLACEHOLDER/${TELEMT_INTERNAL_PORT}/g" \
	    "${REPO_ROOT}/install/traefik-dynamic-tcp.yml" > "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	info "Настроен Traefik: SNI ${FAKE_DOMAIN} -> telemt:${TELEMT_INTERNAL_PORT} (TLS passthrough)"
}

create_panel_admin() {
	cd "${INSTALL_DIR}"
	[[ -f .env ]] && source .env 2>/dev/null || true
	local admin_user="${PANEL_ADMIN_USERNAME:-admin}"
	local admin_pass
	local pass_generated=0
	if [[ -t 0 ]]; then
		echo ""
		echo "Создание первого администратора панели (sudo)."
		echo -n "Имя пользователя [${admin_user}]: " >&2
		read -r input || true
		if [[ -n "$input" ]]; then admin_user="$input"; fi
		echo -n "Пароль (Enter — сгенерировать случайный): " >&2
		read -rs admin_pass || true
		echo "" >&2
		if [[ -z "$admin_pass" ]]; then
			admin_pass=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
			pass_generated=1
			info "Сгенерирован случайный пароль."
		fi
	else
		admin_pass="${PANEL_ADMIN_PASSWORD:-}"
		if [[ -z "$admin_pass" ]]; then
			admin_pass=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
			pass_generated=1
		fi
	fi
	info "Создание учётной записи администратора..."
	if docker compose run --rm panel python -m app.cli create-admin --username "$admin_user" --password "$admin_pass" --sudo 2>/dev/null; then
		info "Администратор ${admin_user} создан."
		PANEL_CREATED_USER="$admin_user"
		PANEL_CREATED_PASS="$admin_pass"
		PANEL_PASS_GENERATED="$pass_generated"
	else
		warn "Не удалось создать админа через CLI. Создайте вручную: cd ${INSTALL_DIR} && docker compose run --rm panel python -m app.cli create-admin --username admin --password YOUR_PASS --sudo"
	fi
}

run_compose() {
	cd "${INSTALL_DIR}"
	if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
		if [[ "${TELEMT_IMAGE_SOURCE}" == "prebuilt" ]]; then
			info "Загрузка образов telemt и panel из Docker Hub..."
			docker compose --progress plain pull
		else
			info "Сборка образов telemt и panel..."
			docker compose build --no-cache 2>/dev/null || docker compose build
		fi
		docker compose up -d
		info "Ожидание готовности панели..."
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			if docker compose exec -T panel curl -sf http://localhost:8080/health >/dev/null 2>&1; then
				break
			fi
			sleep 2
		done
		info "Контейнеры запущены."
	else
		if [[ "${TELEMT_IMAGE_SOURCE}" == "prebuilt" ]]; then
			info "Загрузка образа telemt и запуск контейнеров..."
			docker compose --progress plain pull
			docker compose up -d
		else
			info "Сборка образа telemt и запуск контейнеров..."
			docker compose build --no-cache telemt || docker compose build telemt
			docker compose up -d
		fi
		info "Контейнеры запущены."
	fi
}

print_link() {
	[[ -f "${INSTALL_DIR}/.env" ]] && source "${INSTALL_DIR}/.env" 2>/dev/null || true
	if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
		local port="${PANEL_PORT:-8080}"
		local panel_url="http://localhost:${port}"
		echo ""
		echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
		echo -e "${GREEN}║  Панель управления MTProxy                             ║${NC}"
		echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
		echo ""
		echo -e "  URL:   ${GREEN}${panel_url}${NC}"
		if [[ -n "${PANEL_CREATED_USER:-}" ]]; then
			echo -e "  Логин: ${GREEN}${PANEL_CREATED_USER}${NC}"
			echo -e "  Пароль: ${GREEN}${PANEL_CREATED_PASS}${NC}"
			if [[ "${PANEL_PASS_GENERATED:-0}" == "1" ]]; then
				echo ""
				echo -e "  ${YELLOW}⚠  Пароль сгенерирован автоматически — сохраните его!${NC}"
			fi
		fi
		echo ""
		echo "  Создайте пользователей в панели — ссылки и QR появятся там."
		echo "  Данные установки: ${INSTALL_DIR}"
		echo "  Логи:            cd ${INSTALL_DIR} && docker compose logs -f"
		echo "  Меню управления: $(rerun_cmd)"
		echo "  Остановка:       cd ${INSTALL_DIR} && docker compose down"
		echo ""
		return 0
	fi

	local SECRET TLS_DOMAIN DOMAIN_HEX LONG_SECRET SERVER_IP4 SERVER_IP6 port raw url
	SECRET=$(cat "${INSTALL_DIR}/.secret" 2>/dev/null | tr -d '\n\r')
	if [[ -z "$SECRET" ]]; then err "Секрет не найден в ${INSTALL_DIR}/.secret"; fi

	TLS_DOMAIN=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${INSTALL_DIR}/telemt.toml" \
		| head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
	if [[ -z "$TLS_DOMAIN" ]]; then err "tls_domain не найден в ${INSTALL_DIR}/telemt.toml"; fi

	DOMAIN_HEX=$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')
	if [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
		LONG_SECRET="ee${SECRET}${DOMAIN_HEX}"
	else
		LONG_SECRET="$SECRET"
	fi

	# LISTEN_PORT from .env or default
	port=443
	[[ -f "${INSTALL_DIR}/.env" ]] && source "${INSTALL_DIR}/.env" 2>/dev/null || true
	if [[ -n "$LISTEN_PORT" ]]; then port="$LISTEN_PORT"; fi

	# Сначала IPv4, затем IPv6 (две ссылки при наличии обоих)
	SERVER_IP4=""
	for url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org https://checkip.amazonaws.com; do
		raw=$(curl -4 -s --connect-timeout 3 "$url" 2>/dev/null | tr -d '\n\r')
		if [[ -n "$raw" ]] && [[ ! "$raw" =~ [[:space:]] ]] && [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			SERVER_IP4="$raw"
			break
		fi
	done
	SERVER_IP6=""
	for url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org https://api64.ipify.org; do
		raw=$(curl -6 -s --connect-timeout 3 "$url" 2>/dev/null | tr -d '\n\r')
		if [[ -n "$raw" ]] && [[ ! "$raw" =~ [[:space:]] ]] && [[ "$raw" =~ : ]] && [[ "$raw" =~ ^[0-9a-fA-F:.]+$ ]]; then
			SERVER_IP6="$raw"
			break
		fi
	done
	if [[ -z "$SERVER_IP4" ]] && [[ -z "$SERVER_IP6" ]]; then
		SERVER_IP4="YOUR_SERVER_IP"
		warn "Не удалось определить внешний IP. Подставьте IP сервера в ссылку вручную."
	fi

	echo ""
	echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║  Ссылка для Telegram (Fake TLS)                         ║${NC}"
	echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""
	if [[ -n "$SERVER_IP4" ]] && [[ "$SERVER_IP4" != "YOUR_SERVER_IP" ]]; then
		echo -e "  ${GREEN}tg://proxy?server=${SERVER_IP4}&port=${port}&secret=${LONG_SECRET}${NC}"
	fi
	if [[ -n "$SERVER_IP6" ]]; then
		echo -e "  ${GREEN}tg://proxy?server=${SERVER_IP6}&port=${port}&secret=${LONG_SECRET}${NC}"
	fi
	if [[ "$SERVER_IP4" == "YOUR_SERVER_IP" ]]; then
		echo -e "  ${GREEN}tg://proxy?server=${SERVER_IP4}&port=${port}&secret=${LONG_SECRET}${NC}"
	fi
	echo ""
	echo "  Сохраните ссылку и не публикуйте её публично."
	echo ""
	echo "  Данные установки: ${INSTALL_DIR}"
	echo "  Логи:            cd ${INSTALL_DIR} && docker compose logs -f"
	echo "  Меню управления: $(rerun_cmd)"
	echo "  Остановка:       cd ${INSTALL_DIR} && docker compose down"
	echo ""
}

cmd_install() {
	INSTALL_DIR="$(resolve_install_dir "$INSTALL_DIR")"
	check_docker
	prompt_install_dir
	INSTALL_DIR="$(resolve_install_dir "$INSTALL_DIR")"
	info "Начало установки в ${INSTALL_DIR} ..."
	# If directory already has an installation, offer to update instead
	if [[ -d "$INSTALL_DIR" ]] && [[ -f "${INSTALL_DIR}/docker-compose.yml" ]] && [[ -f "${INSTALL_DIR}/telemt.toml" ]] && [[ -t 0 ]]; then
		info "В каталоге уже есть установка: ${INSTALL_DIR}"
		echo -n "Обновить (перейти в обновление)? (Y/n): " >&2
		read -r ans || true
		ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
		if [[ -z "$ans_lower" ]] || [[ "$ans_lower" == "y" ]] || [[ "$ans_lower" == "д" ]]; then
			cmd_update "$INSTALL_DIR"
			return
		fi
	fi
	prompt_port
	if [[ ! -t 0 ]] && [[ "${LISTEN_PORT:-443}" == "443" ]] && is_port_in_use 443; then
		LISTEN_PORT=1443
		warn "Порт 443 занят. Используется порт 1443."
	fi
	prompt_fake_domain
	confirm_install
	prompt_image_source
	prompt_install_panel

	if [[ "$INSTALL_PANEL" == "yes" ]]; then
		if [[ "$TELEMT_IMAGE_SOURCE" == "prebuilt" ]] && [[ ! -f "${REPO_ROOT}/install/docker-compose.panel.prebuilt.yml" ]]; then
			err "Режим «прокси + панель (prebuilt)» требует файл install/docker-compose.panel.prebuilt.yml. Запускайте из корня репозитория telemt."
		elif [[ "$TELEMT_IMAGE_SOURCE" == "build" ]] && [[ ! -f "${REPO_ROOT}/install/docker-compose.panel.yml" ]]; then
			err "Режим «прокси + панель (build)» требует файл install/docker-compose.panel.yml. Запускайте из корня репозитория telemt."
		fi
	fi

	if [[ "$TELEMT_IMAGE_SOURCE" == "build" ]]; then
		if ! is_build_repo_root "$REPO_ROOT"; then
			ensure_git
			mkdir -p "${INSTALL_DIR}"
			# Prefer env override; else clone under INSTALL_DIR so non-root users can install without /opt
			CLONE_DIR="${CLONE_DIR:-${INSTALL_DIR}/.telemt-source}"
			if [[ -d "${CLONE_DIR}/.git" ]]; then
				info "Обновляю клон репозитория в ${CLONE_DIR} ..."
				(cd "${CLONE_DIR}" && git pull --depth 1 2>/dev/null) || true
			else
				info "Клонирую GrandMax/telemt-panel в ${CLONE_DIR} ..."
				git clone --depth 1 https://github.com/GrandMax/telemt-panel.git "${CLONE_DIR}"
			fi
			REPO_ROOT="${CLONE_DIR}"
		fi
	fi

	copy_and_configure
	run_compose
	if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
		create_panel_admin
	fi
	print_link

	# When run via curl|bash, offer to save script to current dir for management
	if [[ ! -f "$0" ]] && [[ -t 0 ]]; then
		echo -n "Сохранить актуальную версию скрипта в текущий каталог для управления? (Y/n): " >&2
		read -r ans || true
		ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
		if [[ -z "$ans" ]] || [[ "$ans_lower" == "y" ]] || [[ "$ans_lower" == "yes" ]] || [[ "$ans_lower" == "д" ]]; then
			local save_url="https://raw.githubusercontent.com/GrandMax/telemt-panel/main/install.sh"
			local save_path="./install.sh"
			if curl -sSL "$save_url" -o "$save_path" 2>/dev/null; then
				chmod +x "$save_path"
				info "Скрипт сохранён: $(pwd)/install.sh"
			else
				warn "Не удалось скачать скрипт. Сохраните вручную: curl -sSL $save_url -o install.sh && chmod +x install.sh"
			fi
		fi
	fi
}

# Check for newer install.sh and replace if running from repo root with write access.
update_scripts_if_newer() {
	info "Проверка новой версии скрипта в репозитории (SCRIPT_VERSION)..."
	[[ -d "${REPO_ROOT}/install" ]] || return 0
	[[ -f "${REPO_ROOT}/install.sh" ]] || return 0
	[[ -w "${REPO_ROOT}/install.sh" ]] || return 0

	local current="${SCRIPT_VERSION:-}"
	local remote_ver=""
	if [[ -d "${REPO_ROOT}/.git" ]]; then
		(cd "${REPO_ROOT}" && git fetch origin 2>/dev/null) || true
		remote_ver=$(cd "${REPO_ROOT}" && git show origin/HEAD:install.sh 2>/dev/null | head -25 | grep -E '^SCRIPT_VERSION="' | head -1 | sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p')
	fi
	if [[ -z "$remote_ver" ]]; then
		remote_ver=$(curl -sL "https://raw.githubusercontent.com/GrandMax/telemt-panel/main/install.sh" 2>/dev/null | head -25 | grep -E '^SCRIPT_VERSION="' | head -1 | sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p')
	fi
	[[ -n "$remote_ver" ]] || return 0

	local latest
	latest=$(printf '%s\n' "$current" "$remote_ver" | sort -V | tail -1)
	if [[ "$latest" != "$remote_ver" ]] || [[ "$current" == "$remote_ver" ]]; then
		info "Версия скрипта актуальна (${current})."
		return 0
	fi

	if [[ -d "${REPO_ROOT}/.git" ]] && (cd "${REPO_ROOT}" && git show origin/HEAD:install.sh &>/dev/null); then
		(cd "${REPO_ROOT}" && git checkout origin/HEAD -- install.sh 2>/dev/null) && info "Скрипт обновлён до версии ${remote_ver}."
	else
		if curl -sL -o "${REPO_ROOT}/install.sh.new" "https://raw.githubusercontent.com/GrandMax/telemt-panel/main/install.sh" 2>/dev/null; then
			mv "${REPO_ROOT}/install.sh.new" "${REPO_ROOT}/install.sh" && chmod +x "${REPO_ROOT}/install.sh" && info "Скрипт обновлён до версии ${remote_ver}."
		else
			warn "Не удалось загрузить новую версию скрипта."
		fi
	fi
}

cmd_update() {
	info "Обновление (Docker: pull или пересборка и перезапуск)..."
	local dir result
	if [[ $# -gt 0 ]]; then
		dir="$(resolve_install_dir "${1}")"
	else
		info "Укажите каталог установки."
		result="$(prompt_install_dir_existing "${INSTALL_DIR}" "offer")"
		if [[ "$result" == INSTALL:* ]]; then
			INSTALL_DIR="${result#INSTALL:}"
			cmd_install
			return
		fi
		if [[ "$result" == "CANCEL" ]]; then
			info "Отменено."
			return
		fi
		dir="$result"
	fi
	if [[ ! -d "$dir" ]] || ! is_valid_install_dir "$dir"; then
		err "Не похоже на установку telemt: ${dir}"
	fi
	info "Каталог: ${dir}"
	update_scripts_if_newer
	local img_source=build
	if [[ -f "${dir}/.env" ]]; then
		local val
		val=$(grep -E '^TELEMT_IMAGE_SOURCE=' "${dir}/.env" 2>/dev/null | cut -d= -f2-)
		if [[ -n "$val" ]]; then img_source="$val"; fi
	fi
	if is_panel_dir "$dir"; then
		if [[ "$img_source" == "prebuilt" ]]; then
			info "Режим «прокси + панель»: скачиваю образы (pull)..."
			(cd "$dir" && docker compose --progress plain pull)
		else
			info "Режим «прокси + панель»: пересборка образов telemt и panel..."
			(cd "$dir" && docker compose build)
		fi
		info "Перезапускаю контейнеры..."
		(cd "$dir" && docker compose up -d)
	elif [[ "$img_source" == "prebuilt" ]]; then
		info "Скачиваю образ (pull)..."
		(cd "$dir" && docker compose --progress plain pull)
		info "Перезапускаю контейнеры..."
		(cd "$dir" && docker compose up -d)
	else
		info "Пересборка образа (build)..."
		(cd "$dir" && docker compose build telemt)
		info "Перезапускаю контейнеры..."
		(cd "$dir" && docker compose up -d)
	fi
	info "Готово."
	INSTALL_DIR="$dir"
	print_link
}

get_install_dir() {
	resolve_install_dir "${1:-$INSTALL_DIR}"
}

# True if dir uses panel mode (docker-compose has panel service).
is_panel_dir() {
	local dir="${1:-}"
	[[ -f "${dir}/docker-compose.yml" ]] && grep -q "panel:" "${dir}/docker-compose.yml" 2>/dev/null
}

# True if dir looks like a valid telemt install (proxy-only or proxy+panel).
is_valid_install_dir() {
	local dir="${1:-}"
	[[ -f "${dir}/docker-compose.yml" ]] || return 1
	[[ -f "${dir}/traefik/dynamic/tcp.yml" ]] || return 1
	[[ -f "${dir}/telemt.toml" ]] && return 0
	is_panel_dir "$dir"
}

# Prompt for existing install directory (for update/config/uninstall). Returns absolute path.
# Usage: dir=$(prompt_install_dir_existing)  # interactive
# Or: dir=$(prompt_install_dir_existing "/path/default" "offer")  # on dir missing, offer new install (returns INSTALL:<path> if user agrees)
prompt_install_dir_existing() {
	local default="${1:-/opt/mtpannel-data}"
	local offer_install="${2:-}"
	default="$(resolve_install_dir "$default")"
	if [[ -t 0 ]]; then
		# Auto-detect: if default path is a valid install, offer to use it
		if [[ -d "$default" ]] && is_valid_install_dir "$default"; then
			echo -n "Найден каталог установки: ${default}. Использовать? (Y/n): " >&2
			read -r ans || true
			ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
			if [[ -z "$ans_lower" ]] || [[ "$ans_lower" == "y" ]] || [[ "$ans_lower" == "д" ]]; then
				echo "$default"
				return
			fi
		fi
		while true; do
			echo -n "Каталог установки [${default}] (q — отмена): " >&2
			read -r input || true
			input_trimmed=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
			if [[ "$input_trimmed" == "q" ]] || [[ "$input_trimmed" == "quit" ]] || [[ "$input_trimmed" == "отмена" ]] || [[ "$input_trimmed" == "cancel" ]] || [[ "$input_trimmed" == "exit" ]]; then
				echo "CANCEL"
				return
			fi
			if [[ -z "$input" ]]; then input="$default"; fi
			local dir
			dir="$(resolve_install_dir "$input")"
			if [[ ! -d "$dir" ]]; then
				warn "Каталог не найден: ${dir}. Введите другой путь или q для отмены."
				if [[ -n "$offer_install" ]]; then
					echo -n "Выполнить новую установку в этот каталог? (y/N) " >&2
					read -r ans || true
					ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
					if [[ "$ans_lower" == "y" ]] || [[ "$ans_lower" == "д" ]]; then
						echo "INSTALL:${dir}"
						return
					fi
				fi
				continue
			fi
			if ! is_valid_install_dir "$dir"; then
				warn "Не похоже на установку telemt (нет docker-compose.yml или каталога traefik/dynamic, или telemt.toml/панели). Укажите другой каталог или q для отмены."
				continue
			fi
			echo "$dir"
			return
		done
	fi
	echo "$default"
}

cmd_add_panel() {
	info "Добавление панели к существующей установке (только прокси)..."
	local dir result
	if [[ $# -gt 0 ]]; then
		dir="$(resolve_install_dir "${1}")"
	else
		result="$(prompt_install_dir_existing "${INSTALL_DIR}" "offer")"
		if [[ "$result" == INSTALL:* ]]; then
			INSTALL_DIR="${result#INSTALL:}"
			cmd_install
			return
		fi
		if [[ "$result" == "CANCEL" ]]; then
			info "Отменено."
			return
		fi
		dir="$result"
	fi
	if [[ ! -d "$dir" ]] || ! is_valid_install_dir "$dir"; then
		err "Не похоже на установку telemt: ${dir}"
	fi
	if is_panel_dir "$dir"; then
		err "В этом каталоге уже установлена панель (режим «прокси + панель»). Каталог: ${dir}"
	fi
	if [[ ! -f "${dir}/telemt.toml" ]]; then
		err "Добавление панели возможно только к установке с telemt.toml (proxy-only). Каталог: ${dir}"
	fi
	info "Каталог: ${dir}"
	INSTALL_DIR="$dir"
	update_scripts_if_newer

	# Backup and read current settings
	local fake_domain list_port img_source
	fake_domain=$(grep -E '^\s*tls_domain\s*=' "${dir}/telemt.toml" 2>/dev/null | sed -E 's/^[^=]*=\s*["]?([^"]+)["]?.*/\1/' | tr -d ' \r' || echo "example.com")
	list_port=$(grep -E '^LISTEN_PORT=' "${dir}/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || echo "443")
	img_source=$(grep -E '^TELEMT_IMAGE_SOURCE=' "${dir}/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || echo "build")
	cp "${dir}/telemt.toml" "${dir}/telemt.toml.bak" 2>/dev/null || true
	[[ -f "${dir}/.env" ]] && cp "${dir}/.env" "${dir}/.env.bak" 2>/dev/null || true

	info "Останавливаю контейнеры..."
	(cd "$dir" && docker compose down) || true

	info "Подключаю панель и обновляю .env..."
	if [[ "$img_source" == "prebuilt" ]]; then
		sed -e "s|image: grandmax/telemt:latest|image: ${TELEMT_PREBUILT_IMAGE}|g" \
		    -e "s|image: grandmax/telemt-panel:latest|image: ${PANEL_PREBUILT_IMAGE}|g" \
		    "${REPO_ROOT}/install/docker-compose.panel.prebuilt.yml" > "${dir}/docker-compose.yml"
	else
		if [[ ! -f "${REPO_ROOT}/install/docker-compose.panel.yml" ]]; then
			err "Файл install/docker-compose.panel.yml не найден. Запускайте из корня репозитория telemt."
		fi
		cp "${REPO_ROOT}/install/docker-compose.panel.yml" "${dir}/docker-compose.yml"
	fi
	PANEL_SECRET_KEY=$(openssl rand -hex 32)
	{
		echo "REPO_ROOT=${REPO_ROOT}"
		echo "LISTEN_PORT=${list_port}"
		echo "TELEMT_IMAGE_SOURCE=${img_source}"
		echo "PANEL_SECRET_KEY=${PANEL_SECRET_KEY}"
		echo "PANEL_PORT=${PANEL_PORT:-8080}"
		echo "PROXY_HOST=${PROXY_HOST:-localhost}"
		echo "FAKE_DOMAIN=${fake_domain}"
	} > "${dir}/.env"

	INSTALL_PANEL=yes
	TELEMT_IMAGE_SOURCE="$img_source"
	if [[ "$img_source" == "prebuilt" ]]; then
		info "Загрузка образов telemt и panel из Docker Hub..."
		(cd "$dir" && docker compose --progress plain pull)
	else
		info "Сборка образов telemt и panel..."
		(cd "$dir" && docker compose build --no-cache 2>/dev/null || docker compose build)
	fi
	# Pre-populate shared volume with current telemt.toml so panel uses it as template
	info "Копирую текущий конфиг прокси в volume для панели..."
	(cd "$dir" && docker compose run --rm -v "${dir}/telemt.toml:/src/telemt.toml:ro" panel sh -c "cp /src/telemt.toml /app/telemt-config/config.toml" 2>/dev/null) || true
	info "Запуск контейнеров..."
	(cd "$dir" && docker compose up -d)
	info "Ожидание готовности панели..."
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		(cd "$dir" && docker compose exec -T panel curl -sf http://localhost:8080/health >/dev/null 2>&1) && break
		sleep 2
	done
	create_panel_admin
	print_link
}

cmd_reset_password() {
	info "Сброс / установка пароля администратора панели..."
	local dir result
	if [[ $# -gt 0 ]]; then
		dir="$(resolve_install_dir "${1}")"
		shift
	else
		result="$(prompt_install_dir_existing "${INSTALL_DIR}")"
		if [[ "$result" == "CANCEL" ]]; then
			info "Отменено."
			return
		fi
		dir="$result"
	fi
	if ! is_panel_dir "$dir"; then
		err "Панель не установлена в ${dir}. Эта команда только для режима «прокси + панель»."
	fi
	INSTALL_DIR="$dir"
	local admin_user="admin"
	local admin_pass
	if [[ -t 0 ]]; then
		echo -n "Имя пользователя [${admin_user}]: " >&2
		read -r input || true
		if [[ -n "$input" ]]; then admin_user="$input"; fi
		echo -n "Новый пароль (Enter — сгенерировать случайный): " >&2
		read -rs admin_pass || true
		echo "" >&2
		if [[ -z "$admin_pass" ]]; then
			admin_pass=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
			info "Сгенерирован случайный пароль."
		fi
	else
		admin_user="${1:-admin}"
		admin_pass="${2:-}"
		if [[ -z "$admin_pass" ]]; then
			admin_pass=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
		fi
	fi
	cd "$dir"
	if docker compose run --rm panel python -m app.cli reset-password --username "$admin_user" --password "$admin_pass" 2>/dev/null; then
		echo ""
		echo -e "  Пароль обновлён:"
		echo -e "  Логин:  ${GREEN}${admin_user}${NC}"
		echo -e "  Пароль: ${GREEN}${admin_pass}${NC}"
		echo ""
	else
		warn "Не удалось сбросить пароль. Возможно, пользователь '${admin_user}' не существует."
		echo "  Попробуйте создать нового: cd ${dir} && docker compose run --rm panel python -m app.cli create-admin --username ${admin_user} --password YOUR_PASS --sudo"
	fi
}

# Show main menu; set MENU_CHOICE=1..7 (7=exit) and return 0. Only call when [[ -t 0 ]].
# Uses MENU_CHOICE instead of return code so that set -e does not exit when user selects 1.
show_menu() {
	while true; do
		echo ""
		echo -e "  ${GREEN}MTpannel${NC}"
		echo ""
		echo "  1) Установка (новая установка в каталог)"
		echo "  2) Обновление (Docker: pull или пересборка и перезапуск)"
		echo "  3) Смена домена (SNI)"
		echo "  4) Удаление"
		echo "  5) Добавить панель (к установке «только прокси»)"
		echo "  6) Сброс пароля администратора панели"
		echo "  7) Выход"
		echo ""
		echo -n "Выберите действие [1-7]: "
		read -r choice || true
		choice="${choice%% *}"
		case "$choice" in
			1) MENU_CHOICE=1; return 0 ;;
			2) MENU_CHOICE=2; return 0 ;;
			3) MENU_CHOICE=3; return 0 ;;
			4) MENU_CHOICE=4; return 0 ;;
			5) MENU_CHOICE=5; return 0 ;;
			6) MENU_CHOICE=6; return 0 ;;
			7) MENU_CHOICE=7; return 0 ;;
			*) warn "Введите число от 1 до 7." ;;
		esac
	done
}

cmd_config() {
	info "Смена домена (SNI)..."
	local new_domain=""
	local dir=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--sni) new_domain="$2"; shift 2 ;;
			*) shift ;;
		esac
	done

	if [[ -n "$new_domain" ]]; then
		dir="$(get_install_dir)"
	else
		info "Укажите каталог установки."
		local result
		result="$(prompt_install_dir_existing "${INSTALL_DIR}" "offer")"
		if [[ "$result" == INSTALL:* ]]; then
			INSTALL_DIR="${result#INSTALL:}"
			cmd_install
			return
		fi
		if [[ "$result" == "CANCEL" ]]; then
			info "Отменено."
			return
		fi
		dir="$result"
	fi

	if [[ ! -f "${dir}/traefik/dynamic/tcp.yml" ]]; then
		err "Каталог установки не найден или неполный: ${dir}"
	fi
	if [[ ! -f "${dir}/telemt.toml" ]] && grep -q "panel:" "${dir}/docker-compose.yml" 2>/dev/null; then
		info "Режим «прокси + панель»: домен задаётся в ${dir}/.env (FAKE_DOMAIN). Отредактируйте .env и выполните: cd ${dir} && docker compose up -d --force-recreate"
		return 0
	fi
	if [[ ! -f "${dir}/telemt.toml" ]]; then
		err "Каталог установки не найден или неполный: ${dir}"
	fi
	info "Каталог: ${dir}"

	local current_domain
	current_domain=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${dir}/telemt.toml" | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')

	if [[ -z "$new_domain" ]]; then
		if [[ -t 0 ]]; then
			echo -n "Новый домен для Fake TLS (tls_domain) [${current_domain}]: " >&2
			read -r new_domain || true
			if [[ -z "$new_domain" ]]; then new_domain="$current_domain"; fi
		else
			err "Без TTY укажите домен через env FAKE_DOMAIN или аргумент: install.sh config --sni example.com"
		fi
	fi

	if [[ -z "$new_domain" ]]; then err "Домен не задан."; fi

	# Update telemt.toml
	sed -i.bak -E "s/^([[:space:]]*tls_domain[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"${new_domain}\"/" "${dir}/telemt.toml"
	rm -f "${dir}/telemt.toml.bak"

	# Update traefik tcp.yml (replace HostSNI(`...`) with new domain)
	local tcp_yml="${dir}/traefik/dynamic/tcp.yml"
	# Perl: replace domain between backticks (avoids shell/sed escaping of backticks)
	NEW_DOMAIN="$new_domain" perl -i -pe 's/HostSNI\(`[^`]*`\)/HostSNI(`$ENV{NEW_DOMAIN}`)/' "$tcp_yml" 2>/dev/null || {
		if sed --version 2>/dev/null | grep -q GNU; then
			sed -i "s/HostSNI(\`[^\`]*\`)/HostSNI(\`${new_domain}\`)/" "$tcp_yml"
		else
			sed -i '' "s/HostSNI(\`[^\`]*\`)/HostSNI(\`${new_domain}\`)/" "$tcp_yml"
		fi
	}

	info "Домен обновлён на ${new_domain}."
	info "Перезапускаю контейнеры..."
	(cd "$dir" && docker compose up -d --force-recreate)
	INSTALL_DIR="$dir"
	print_link
}

cmd_uninstall() {
	info "Удаление установки..."
	local force=""
	local dir=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-y|--yes) force=1; shift ;;
			*)
				dir="$1"
				shift
				break
				;;
		esac
	done

	if [[ -z "$dir" ]] && [[ -t 0 ]]; then
		info "Укажите каталог установки для удаления."
		dir="$(prompt_install_dir_existing "${INSTALL_DIR}")"
		if [[ "$dir" == "CANCEL" ]]; then
			info "Отменено."
			return 0
		fi
	else
		dir="$(resolve_install_dir "${dir:-$INSTALL_DIR}")"
	fi

	if [[ ! -d "$dir" ]]; then
		err "Каталог не найден: ${dir}"
	fi
	if ! is_valid_install_dir "$dir"; then
		err "Не похоже на установку telemt: ${dir}"
	fi
	info "Каталог: ${dir}"

	# Собрать список образов до любых деструктивных действий
	local uninstall_images
	uninstall_images=$(grep -E '^[[:space:]]+image:[[:space:]]+' "${dir}/docker-compose.yml" 2>/dev/null | sed -E 's/^[[:space:]]*image:[[:space:]]*["]?([^"]+)["]?.*/\1/' | tr -d ' \r' | sort -u || true)
	uninstall_images=$(printf '%s' "$uninstall_images" | grep -v '^$' || true)

	if [[ -z "$force" ]] && [[ -t 0 ]]; then
		echo -n "Удалить установку в ${dir}? [Y/n] " >&2
		read -r ans || true
		ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
		if [[ "$ans_lower" == "n" ]] || [[ "$ans_lower" == "no" ]]; then
			info "Отменено."
			return 0
		fi
	fi

	info "Выполняю: docker compose down -v (каталог: ${dir})"
	(cd "$dir" && docker compose down -v) || true
	info "Контейнеры и тома удалены."

	if [[ -n "$uninstall_images" ]] && [[ -t 0 ]]; then
		echo ""
		info "Образы Docker, использовавшиеся установкой:"
		printf '%s\n' "$uninstall_images" | while read -r img; do [[ -n "$img" ]] && echo "  - $img"; done
		warn "Образ traefik может использоваться другими проектами."
		echo -n "Удалить эти образы? [y/N] " >&2
		read -r ans || true
		ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
		if [[ "$ans_lower" == "y" ]] || [[ "$ans_lower" == "yes" ]] || [[ "$ans_lower" == "д" ]]; then
			local removed=0
			while IFS= read -r img; do
				[[ -z "$img" ]] && continue
				info "Удаляю образ: ${img}"
				if docker rmi "$img" 2>/dev/null; then removed=$((removed + 1)); else warn "Не удалось удалить образ: $img"; fi
			done <<< "$uninstall_images"
			[[ $removed -gt 0 ]] && info "Образы удалены."
		fi
		echo ""
	fi

	info "Удаляю каталог ${dir} ..."
	rm -rf "$dir"
	info "Готово."
}

usage() {
	echo "Использование: $0 [install | update | config | uninstall | add-panel | reset-password] [опции]"
	echo ""
	echo "  Без аргументов (при наличии TTY): интерактивное меню — выбор действия и ввод всех"
	echo "  параметров диалогами внутри скрипта (каталог, порт, домен SNI, подтверждения)."
	echo ""
	echo "  С аргументом действия — для скриптов/CI, параметры из переменных окружения:"
	echo "  INSTALL_DIR, LISTEN_PORT, FAKE_DOMAIN, FAKE_DOMAIN_FROM_ENV. Для config без TTY:"
	echo "  FAKE_DOMAIN или --sni DOMAIN. Для uninstall: INSTALL_DIR, при необходимости -y."
	echo ""
	echo "  install    — установка"
	echo "  update     — обновление образа и перезапуск"
	echo "  config     — смена домена Fake TLS (SNI)"
	echo "  uninstall  — удаление установки"
	echo "  add-panel        — добавить панель к установке «только прокси»"
	echo "  reset-password   — сброс пароля администратора панели"
	exit 0
}

main() {
	if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
		usage
	fi

	# Interactive menu: no args (when run via curl|bash, redirect stdin from /dev/tty so menu works)
	if [[ $# -eq 0 ]]; then
		if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
			exec 0</dev/tty
		fi
		check_docker
		while true; do
			MENU_CHOICE=0
			show_menu
			choice="${MENU_CHOICE:-0}"
			case "$choice" in
				1) cmd_install ;;
				2) cmd_update ;;
				3) cmd_config ;;
				4) cmd_uninstall ;;
				5) cmd_add_panel ;;
				6) cmd_reset_password ;;
				7) info "Выход."; exit 0 ;;
				*) ;;
			esac
		done
		return
	fi

	# Non-interactive: action from first argument, params from env
	local cmd="${1:-install}"
	if [[ $# -gt 0 ]]; then shift; fi
	case "$cmd" in
		install)    cmd_install "$@" ;;
		update)     cmd_update "$@" ;;
		config)     cmd_config "$@" ;;
		uninstall)  cmd_uninstall "$@" ;;
		add-panel)       cmd_add_panel "$@" ;;
		reset-password)  cmd_reset_password "$@" ;;
		*) err "Неизвестная подкоманда: $cmd. Запустите без аргументов для меню или: install | update | config | uninstall | add-panel | reset-password" ;;
	esac
}

main "$@"