#!/usr/bin/env bash
# Telemt MTProxy installer: fully interactive menu when run with no args (TTY).
# Uses local templates from install/; builds telemt from repo Dockerfile.
# Non-interactive: pass action as first arg and use env vars (INSTALL_DIR, LISTEN_PORT, FAKE_DOMAIN, etc.).

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtpannel-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-pikabu.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"
LISTEN_PORT="${LISTEN_PORT:-443}"
TELEMT_PREBUILT_IMAGE="${TELEMT_PREBUILT_IMAGE:-grandmax/telemt-pannel:latest}"
TELEMT_IMAGE_SOURCE="${TELEMT_IMAGE_SOURCE:-prebuilt}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

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
		local default="${INSTALL_DIR}"
		echo -n "Каталог установки [${default}]: "
		read -r input || true
		if [[ -n "$input" ]]; then INSTALL_DIR="$input"; fi
	fi
}

prompt_port() {
	local suggested=443
	if is_port_in_use 443; then
		warn "Порт 443 занят."
		suggested=1443
		while true; do
			if [[ -t 0 ]]; then
				echo -n "Введите порт [${suggested}]: "
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
			echo -n "Порт для прокси [443]: "
			read -r input || true
			if [[ -z "$input" ]]; then input=443; fi
			while true; do
				if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
					if is_port_in_use "$input"; then
						warn "Порт ${input} занят, выберите другой."
						echo -n "Введите порт: "
						read -r input || true
					else
						LISTEN_PORT=$input
						return
					fi
				else
					warn "Введите число от 1 до 65535."
					echo -n "Введите порт [443]: "
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
		echo -n "Домен для маскировки Fake TLS (SNI) [${FAKE_DOMAIN}]: "
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
	echo -n "Продолжить? [Y/n] "
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
		echo "Образ telemt:"
		echo "  1) Скачать готовый образ (${TELEMT_PREBUILT_IMAGE})"
		echo "  2) Собрать из исходников (локально)"
		echo -n "Выбор [1]: "
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

generate_secret() {
	openssl rand -hex 16
}

copy_and_configure() {
	info "Создаю каталоги и копирую шаблоны из ${REPO_ROOT}/install/ ..."
	mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

	if [[ ! -f "${REPO_ROOT}/install/docker-compose.yml" ]] || [[ ! -f "${REPO_ROOT}/install/telemt.toml.example" ]] || [[ ! -f "${REPO_ROOT}/install/traefik-dynamic-tcp.yml" ]]; then
		err "Шаблоны не найдены в ${REPO_ROOT}/install/. Запускайте скрипт из корня репозитория telemt."
	fi

	if [[ "$TELEMT_IMAGE_SOURCE" == "prebuilt" ]]; then
		if [[ ! -f "${REPO_ROOT}/install/docker-compose.prebuilt.yml" ]]; then
			err "Шаблон docker-compose.prebuilt.yml не найден в ${REPO_ROOT}/install/."
		fi
		sed -e "s|image: grandmax/telemt-pannel:latest|image: ${TELEMT_PREBUILT_IMAGE}|g" \
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

	sed -e "s/SNI_DOMAIN_PLACEHOLDER/${FAKE_DOMAIN}/g" \
	    -e "s/TELEMT_PORT_PLACEHOLDER/${TELEMT_INTERNAL_PORT}/g" \
	    "${REPO_ROOT}/install/traefik-dynamic-tcp.yml" > "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	info "Настроен Traefik: SNI ${FAKE_DOMAIN} -> telemt:${TELEMT_INTERNAL_PORT} (TLS passthrough)"

	printf '%s' "$SECRET" > "${INSTALL_DIR}/.secret"

	# .env for docker compose (REPO_ROOT, LISTEN_PORT, TELEMT_IMAGE_SOURCE)
	{
		echo "REPO_ROOT=${REPO_ROOT}"
		echo "LISTEN_PORT=${LISTEN_PORT}"
		echo "TELEMT_IMAGE_SOURCE=${TELEMT_IMAGE_SOURCE}"
	} > "${INSTALL_DIR}/.env"
}

run_compose() {
	cd "${INSTALL_DIR}"
	if [[ "${TELEMT_IMAGE_SOURCE}" == "prebuilt" ]]; then
		info "Загрузка образа telemt и запуск контейнеров..."
		docker compose pull telemt
		docker compose up -d
	else
		info "Сборка образа telemt и запуск контейнеров..."
		docker compose build --no-cache telemt || docker compose build telemt
		docker compose up -d
	fi
	info "Контейнеры запущены."
}

print_link() {
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
	info "Начало установки в ${INSTALL_DIR} ..."
	check_docker
	prompt_install_dir
	prompt_port
	prompt_fake_domain
	confirm_install
	prompt_image_source

	if [[ "$TELEMT_IMAGE_SOURCE" == "build" ]]; then
		if ! is_build_repo_root "$REPO_ROOT"; then
			ensure_git
			mkdir -p "${INSTALL_DIR}"
			CLONE_DIR="${INSTALL_DIR}/.telemt-source"
			if [[ -d "${CLONE_DIR}/.git" ]]; then
				info "Обновляю клон репозитория в ${CLONE_DIR} ..."
				(cd "${CLONE_DIR}" && git pull --depth 1 2>/dev/null) || true
			else
				info "Клонирую GrandMax/telemt-pannel в ${CLONE_DIR} ..."
				git clone --depth 1 https://github.com/GrandMax/telemt-pannel.git "${CLONE_DIR}"
			fi
			REPO_ROOT="${CLONE_DIR}"
		fi
	fi

	copy_and_configure
	run_compose
	print_link
}

cmd_update() {
	local dir
	if [[ $# -gt 0 ]]; then
		dir="$(resolve_install_dir "${1}")"
	else
		dir="$(prompt_install_dir_existing "${INSTALL_DIR}")"
	fi
	if [[ ! -d "$dir" ]] || [[ ! -f "${dir}/docker-compose.yml" ]] || [[ ! -f "${dir}/telemt.toml" ]]; then
		err "Не похоже на установку telemt (нет docker-compose.yml или telemt.toml): ${dir}"
	fi
	local img_source=build
	if [[ -f "${dir}/.env" ]]; then
		local val
		val=$(grep -E '^TELEMT_IMAGE_SOURCE=' "${dir}/.env" 2>/dev/null | cut -d= -f2-)
		if [[ -n "$val" ]]; then img_source="$val"; fi
	fi
	info "Обновление образа telemt в ${dir} ..."
	if [[ "$img_source" == "prebuilt" ]]; then
		(cd "$dir" && docker compose pull telemt && docker compose up -d)
	else
		if [[ -f "${dir}/.env" ]]; then
			repo_root=""
			# shellcheck source=/dev/null
			repo_root=$(grep -E '^REPO_ROOT=' "${dir}/.env" 2>/dev/null | cut -d= -f2-)
			if [[ -n "$repo_root" ]] && [[ -d "$repo_root/.git" ]] && [[ "$repo_root" == "${dir}"* ]]; then
				info "Обновляю исходники в ${repo_root} ..."
				(cd "$repo_root" && git pull --depth 1 2>/dev/null) || true
			fi
		fi
		(cd "$dir" && docker compose build --no-cache telemt && docker compose up -d)
	fi
	info "Готово."
	INSTALL_DIR="$dir"
	print_link
}

get_install_dir() {
	resolve_install_dir "${1:-$INSTALL_DIR}"
}

# Prompt for existing install directory (for update/config/uninstall). Returns absolute path.
# Usage: dir=$(prompt_install_dir_existing)  # interactive
# Or pass default: prompt_install_dir_existing "/path/default"
prompt_install_dir_existing() {
	local default="${1:-$(pwd)/mtpannel-data}"
	default="$(resolve_install_dir "$default")"
	if [[ -t 0 ]]; then
		while true; do
			echo -n "Каталог установки [${default}]: "
			read -r input || true
			if [[ -z "$input" ]]; then input="$default"; fi
			local dir
			dir="$(resolve_install_dir "$input")"
			if [[ ! -d "$dir" ]]; then
				warn "Каталог не найден: ${dir}"
				continue
			fi
			if [[ ! -f "${dir}/docker-compose.yml" ]] || [[ ! -f "${dir}/telemt.toml" ]]; then
				warn "Не похоже на установку telemt (нет docker-compose.yml или telemt.toml). Укажите другой каталог."
				continue
			fi
			echo "$dir"
			return
		done
	fi
	echo "$default"
}

# Show main menu; set MENU_CHOICE=1..5 (5=exit) and return 0. Only call when [[ -t 0 ]].
# Uses MENU_CHOICE instead of return code so that set -e does not exit when user selects 1.
show_menu() {
	while true; do
		echo ""
		echo -e "  ${GREEN}Telemt MTProxy — установка и управление${NC}"
		echo ""
		echo "  1) Установка (новая установка в каталог)"
		echo "  2) Обновление (пересборка и перезапуск)"
		echo "  3) Смена домена (SNI)"
		echo "  4) Удаление"
		echo "  5) Выход"
		echo ""
		echo -n "Выберите действие [1-5]: "
		read -r choice || true
		choice="${choice%% *}"
		case "$choice" in
			1) MENU_CHOICE=1; return 0 ;;
			2) MENU_CHOICE=2; return 0 ;;
			3) MENU_CHOICE=3; return 0 ;;
			4) MENU_CHOICE=4; return 0 ;;
			5) MENU_CHOICE=5; return 0 ;;
			*) warn "Введите число от 1 до 5." ;;
		esac
	done
}

cmd_config() {
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
		# Interactive: first ask for install dir
		dir="$(prompt_install_dir_existing "${INSTALL_DIR}")"
	fi

	if [[ ! -f "${dir}/telemt.toml" ]] || [[ ! -f "${dir}/traefik/dynamic/tcp.yml" ]]; then
		err "Каталог установки не найден или неполный: ${dir}"
	fi

	local current_domain
	current_domain=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${dir}/telemt.toml" | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')

	if [[ -z "$new_domain" ]]; then
		if [[ -t 0 ]]; then
			echo -n "Новый домен для Fake TLS (tls_domain) [${current_domain}]: "
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

	info "Домен обновлён на ${new_domain}. Перезапуск контейнеров..."
	(cd "$dir" && docker compose up -d --force-recreate)
	INSTALL_DIR="$dir"
	print_link
}

cmd_uninstall() {
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
		dir="$(prompt_install_dir_existing "${INSTALL_DIR}")"
	else
		dir="$(resolve_install_dir "${dir:-$INSTALL_DIR}")"
	fi

	if [[ ! -d "$dir" ]]; then
		err "Каталог не найден: ${dir}"
	fi
	if [[ ! -f "${dir}/docker-compose.yml" ]] || [[ ! -f "${dir}/telemt.toml" ]]; then
		err "Не похоже на установку telemt (нет docker-compose.yml или telemt.toml): ${dir}"
	fi

	if [[ -z "$force" ]] && [[ -t 0 ]]; then
		echo -n "Удалить установку в ${dir}? [y/N] "
		read -r ans || true
		ans_lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
		if [[ "$ans_lower" != "y" ]] && [[ "$ans_lower" != "yes" ]]; then exit 0; fi
	fi

	info "Останавливаю контейнеры..."
	(cd "$dir" && docker compose down -v 2>/dev/null) || true
	info "Удаляю каталог ${dir} ..."
	rm -rf "$dir"
	info "Готово."
}

usage() {
	echo "Использование: $0 [install | update | config | uninstall] [опции]"
	echo ""
	echo "  Без аргументов (при наличии TTY): интерактивное меню — выбор действия и ввод всех"
	echo "  параметров диалогами внутри скрипта (каталог, порт, домен SNI, подтверждения)."
	echo ""
	echo "  С аргументом действия — для скриптов/CI, параметры из переменных окружения:"
	echo "  INSTALL_DIR, LISTEN_PORT, FAKE_DOMAIN, FAKE_DOMAIN_FROM_ENV. Для config без TTY:"
	echo "  FAKE_DOMAIN или --sni DOMAIN. Для uninstall: INSTALL_DIR, при необходимости -y."
	echo ""
	echo "  install   — установка"
	echo "  update    — обновление образа и перезапуск"
	echo "  config    — смена домена Fake TLS (SNI)"
	echo "  uninstall — удаление установки"
	exit 0
}

main() {
	if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
		usage
	fi

	# Interactive menu: no args and TTY
	if [[ $# -eq 0 ]] && [[ -t 0 ]]; then
		check_docker
		MENU_CHOICE=0
		show_menu
		choice="${MENU_CHOICE:-0}"
		case "$choice" in
			1) cmd_install ;;
			2) cmd_update ;;
			3) cmd_config ;;
			4) cmd_uninstall ;;
			5) info "Выход."; exit 0 ;;
			*) exit 0 ;;
		esac
		return
	fi

	# Non-interactive: action from first argument, params from env
	local cmd="${1:-install}"
	if [[ $# -gt 0 ]]; then shift; fi
	case "$cmd" in
		install)  cmd_install "$@" ;;
		update)   cmd_update "$@" ;;
		config)   cmd_config "$@" ;;
		uninstall) cmd_uninstall "$@" ;;
		*) err "Неизвестная подкоманда: $cmd. Запустите без аргументов для меню или: install | update | config | uninstall" ;;
	esac
}

main "$@"