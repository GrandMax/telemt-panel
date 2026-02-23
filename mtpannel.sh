#!/usr/bin/env bash
# MTpannel — интерактивное управление (установка, обновление, смена SNI, удаление).
# С псевдографикой: рамки, разделители, цветные сообщения.
# Без аргументов и TTY: главное меню. С аргументом: install | update | config | uninstall (параметры из env).

# Под стандартным терминалом macOS (и при sh) принудительно запускаем через bash
if [[ -z "${BASH_VERSION:-}" ]]; then
	exec /usr/bin/env bash "$0" "$@"
fi

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtpannel-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-pikabu.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"
LISTEN_PORT="${LISTEN_PORT:-443}"
TELEMT_PREBUILT_IMAGE="${TELEMT_PREBUILT_IMAGE:-grandmax/telemt-pannel:latest}"
TELEMT_IMAGE_SOURCE="${TELEMT_IMAGE_SOURCE:-prebuilt}"
SCRIPT_VERSION="1.0.0"

# Режим «plain»: без цветов и с ASCII-рамкой (для dumb-терминала или когда вывод не в TTY)
if [[ "${TERM:-dumb}" == "dumb" ]] || [[ ! -t 1 ]]; then
	USE_PLAIN=1
else
	USE_PLAIN=0
fi

# Цвета: tput (macOS/Linux), при неудаче — ANSI через $'\033' (переносимо)
if [[ "$USE_PLAIN" -eq 1 ]]; then
	BOLD_RED=""; BOLD_GREEN=""; ORANGE=""; YELLOW=""; GREEN=""; CYAN=""; NC=""
else
	BOLD_RED="$(tput setaf 1 2>/dev/null; tput bold 2>/dev/null)" || true
	BOLD_GREEN="$(tput setaf 2 2>/dev/null; tput bold 2>/dev/null)" || true
	ORANGE="$(tput setaf 3 2>/dev/null)" || true
	YELLOW="$(tput setaf 3 2>/dev/null)" || true
	GREEN="$(tput setaf 2 2>/dev/null)" || true
	CYAN="$(tput setaf 6 2>/dev/null)" || true
	NC="$(tput sgr0 2>/dev/null)" || true
	# Если tput ничего не дал (нет terminfo), используем ANSI-коды
	if [[ -z "${BOLD_GREEN}" ]]; then
		BOLD_RED=$'\033[1;31m'; BOLD_GREEN=$'\033[1;32m'; NC=$'\033[0m'
		ORANGE=$'\033[33m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'
	fi
fi

# Рамка: в plain-режиме ASCII (+ - |), иначе Unicode
if [[ "$USE_PLAIN" -eq 1 ]]; then
	BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="|"; BOX_LINE="-"
else
	BOX_TL="┌"; BOX_TR="┐"; BOX_BL="└"; BOX_BR="┘"; BOX_H="│"; BOX_LINE="─"
fi

BOX_WIDTH=58

# --- Псевдографика ---
clear_screen() {
	clear
}

draw_section_header() {
	local title="$1"
	local width="${2:-$BOX_WIDTH}"
	local padding_left=$(((width - ${#title}) / 2))
	local padding_right=$((width - padding_left - ${#title}))
	local line pad_l pad_r
	printf -v line '%*s' "$width" ''; line=${line// /$BOX_LINE}
	printf -v pad_l '%*s' "$padding_left" ''
	printf -v pad_r '%*s' "$padding_right" ''
	printf '\n'
	printf '%s%s%s%s%s\n' "${BOLD_GREEN}" "$BOX_TL" "$line" "$BOX_TR" "${NC}"
	printf '%s%s%*s%s%*s%s%s%s\n' "${BOLD_GREEN}" "$BOX_H" "$padding_left" "" "$title" "$padding_right" "" "${BOLD_GREEN}" "$BOX_H" "${NC}"
	printf '%s%s%s%s%s\n' "${BOLD_GREEN}" "$BOX_BL" "$line" "$BOX_BR" "${NC}"
	printf '\n'
}

draw_menu_options() {
	local options=("$@")
	local idx=1
	for option in "${options[@]}"; do
		printf '  %s%d.%s %s\n' "${ORANGE}" "$idx" "${NC}" "$option"
		((idx++)) || true
	done
	printf '\n'
}

draw_separator() {
	local width="${1:-$BOX_WIDTH}"
	local char="${2:-$BOX_LINE}"
	local line
	printf -v line '%*s' "$width" ''; line=${line// /$char}
	printf '%s\n' "$line"
}

draw_info_row() {
	local label="$1"
	local value="$2"
	printf '  %s%s:%s %s%s%s\n' "${ORANGE}" "$label" "${NC}" "${GREEN}" "$value" "${NC}"
}

show_success() {
	printf '%s%s%s %s\n' "${BOLD_GREEN}" "✓" "${NC}" "$*"
}

show_error() {
	printf '%s%s%s %s\n' "${BOLD_RED}" "✗" "${NC}" "$*" >&2
}

show_warning() {
	printf '%s%s%s %s\n' "${YELLOW}" "⚠" "${NC}" "$*" >&2
}

show_info() {
	printf '%s%s%s %s\n' "${CYAN}" "ℹ" "${NC}" "$*" >&2
}

# --- Ввод (с защитой от set -e) ---
prompt_input() {
	local prompt_text="$1"
	local default="$2"
	printf '%s' "${GREEN}${prompt_text}${NC}" >&2
	[[ -n "$default" ]] && printf ' [%s]' "$default" >&2
	printf ': ' >&2
	read -r input || true
	if [[ -z "$input" ]] && [[ -n "$default" ]]; then
		echo "$default"
	else
		echo "$input"
	fi
}

prompt_yes_no() {
	local prompt_text="$1"
	local default="${2:-y}"
	printf '%s (y/n) [%s]: ' "${GREEN}${prompt_text}${NC}" "$default" >&2
	read -r ans || true
	if [[ -z "$ans" ]]; then
		ans="$default"
	fi
	ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
	if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
		return 0
	fi
	return 1
}

prompt_menu_option() {
	local prompt_text="$1"
	local min="${2:-1}"
	local max="${3:-5}"
	local selected
	while true; do
		printf '%s (%s-%s): ' "${GREEN}${prompt_text}${NC}" "$min" "$max" >&2
		read -r selected || true
		printf '\n' >&2
		if [[ "$selected" =~ ^[0-9]+$ ]] && (( selected >= min && selected <= max )); then
			echo "$selected"
			return 0
		fi
		show_warning "Введите число от ${min} до ${max}."
	done
}

# --- Утилиты ---
resolve_install_dir() {
	local d="$1"
	case "$d" in
		/*) echo "$d" ;;
		*) echo "$(pwd)/${d}" ;;
	esac
}

rerun_cmd() {
	echo "bash ${REPO_ROOT}/mtpannel.sh"
}

check_docker() {
	if command -v docker &>/dev/null; then
		if docker info &>/dev/null 2>&1; then
			show_success "Docker доступен."
			return 0
		fi
		echo ""
		show_warning "Docker установлен, но текущий пользователь не в группе docker."
		echo ""
		echo "Выполните: ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo "Затем: $(rerun_cmd)"
		echo ""
		exit 1
	fi
	show_info "Установка Docker..."
	curl -fsSL https://get.docker.com | sh
	if ! docker info &>/dev/null 2>&1; then
		echo ""
		show_warning "Добавьте пользователя в группу docker: ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo "Затем: $(rerun_cmd)"
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
	show_info "Для сборки из исходников нужен git. Попытка установки..."
	if command -v apt-get &>/dev/null; then
		if apt-get update &>/dev/null && apt-get install -y git &>/dev/null; then
			show_success "git установлен."
			return 0
		fi
	fi
	if command -v dnf &>/dev/null; then
		if dnf install -y git &>/dev/null; then
			show_success "git установлен."
			return 0
		fi
	fi
	if command -v yum &>/dev/null; then
		if yum install -y git &>/dev/null; then
			show_success "git установлен."
			return 0
		fi
	fi
	err "Установите git вручную для варианта «Собрать из исходников» (apt install git / dnf install git / yum install git)."
}

generate_secret() {
	openssl rand -hex 16
}

err() {
	show_error "$*"
	exit 1
}

# --- Копирование конфигов и запуск ---
copy_and_configure() {
	show_info "Создаю каталоги и копирую шаблоны из ${REPO_ROOT}/install/ ..."
	mkdir -p "${INSTALL_DIR}"
	mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

	if [[ ! -f "${REPO_ROOT}/install/docker-compose.yml" ]] || [[ ! -f "${REPO_ROOT}/install/telemt.toml.example" ]] || [[ ! -f "${REPO_ROOT}/install/traefik-dynamic-tcp.yml" ]]; then
		err "Шаблоны не найдены в ${REPO_ROOT}/install/. Запускайте скрипт из корня репозитория telemt."
	fi

	if [[ "$TELEMT_IMAGE_SOURCE" == "prebuilt" ]]; then
		if [[ ! -f "${REPO_ROOT}/install/docker-compose.prebuilt.yml" ]]; then
			err "Шаблон docker-compose.prebuilt.yml не найден."
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
	show_success "Создан telemt.toml (домен: ${FAKE_DOMAIN})"

	sed -e "s/SNI_DOMAIN_PLACEHOLDER/${FAKE_DOMAIN}/g" \
	    -e "s/TELEMT_PORT_PLACEHOLDER/${TELEMT_INTERNAL_PORT}/g" \
	    "${REPO_ROOT}/install/traefik-dynamic-tcp.yml" > "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	show_success "Traefik: SNI ${FAKE_DOMAIN} -> telemt:${TELEMT_INTERNAL_PORT}"

	printf '%s' "$SECRET" > "${INSTALL_DIR}/.secret"
	{
		echo "REPO_ROOT=${REPO_ROOT}"
		echo "LISTEN_PORT=${LISTEN_PORT}"
		echo "TELEMT_IMAGE_SOURCE=${TELEMT_IMAGE_SOURCE}"
	} > "${INSTALL_DIR}/.env"
}

run_compose() {
	cd "${INSTALL_DIR}"
	if [[ "${TELEMT_IMAGE_SOURCE}" == "prebuilt" ]]; then
		show_info "Загрузка образа telemt и запуск контейнеров..."
		docker compose --progress plain pull telemt
		docker compose up -d
	else
		show_info "Сборка образа telemt и запуск контейнеров..."
		docker compose build --no-cache telemt || docker compose build telemt
		docker compose up -d
	fi
	show_success "Контейнеры запущены."
}

print_link() {
	local SECRET TLS_DOMAIN DOMAIN_HEX LONG_SECRET SERVER_IP4 SERVER_IP6 port raw url
	SECRET=$(cat "${INSTALL_DIR}/.secret" 2>/dev/null | tr -d '\n\r')
	if [[ -z "$SECRET" ]]; then err "Секрет не найден в ${INSTALL_DIR}/.secret"; fi

	TLS_DOMAIN=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${INSTALL_DIR}/telemt.toml" \
		| head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
	if [[ -z "$TLS_DOMAIN" ]]; then err "tls_domain не найден в telemt.toml"; fi

	DOMAIN_HEX=$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')
	if [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
		LONG_SECRET="ee${SECRET}${DOMAIN_HEX}"
	else
		LONG_SECRET="$SECRET"
	fi

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
		show_warning "Не удалось определить внешний IP. Подставьте IP в ссылку вручную."
	fi

	draw_section_header "Ссылка для Telegram (Fake TLS)" "$BOX_WIDTH"
	if [[ -n "$SERVER_IP4" ]] && [[ "$SERVER_IP4" != "YOUR_SERVER_IP" ]]; then
		printf '  %stg://proxy?server=%s&port=%s&secret=%s%s\n' "${GREEN}" "$SERVER_IP4" "$port" "$LONG_SECRET" "${NC}"
	fi
	if [[ -n "$SERVER_IP6" ]]; then
		printf '  %stg://proxy?server=%s&port=%s&secret=%s%s\n' "${GREEN}" "$SERVER_IP6" "$port" "$LONG_SECRET" "${NC}"
	fi
	if [[ "$SERVER_IP4" == "YOUR_SERVER_IP" ]]; then
		printf '  %stg://proxy?server=%s&port=%s&secret=%s%s\n' "${GREEN}" "$SERVER_IP4" "$port" "$LONG_SECRET" "${NC}"
	fi
	echo ""
	draw_info_row "Сохраните ссылку" "не публикуйте её публично"
	draw_info_row "Данные установки" "${INSTALL_DIR}"
	draw_info_row "Логи" "cd ${INSTALL_DIR} && docker compose logs -f"
	draw_info_row "Меню управления" "$(rerun_cmd)"
	draw_info_row "Остановка" "cd ${INSTALL_DIR} && docker compose down"
	echo ""
}

# --- Выбор каталога существующей установки ---
get_install_dir() {
	resolve_install_dir "${1:-$INSTALL_DIR}"
}

prompt_install_dir_existing() {
	local default="${1:-$(pwd)/mtpannel-data}"
	local offer_install="${2:-}"
	default="$(resolve_install_dir "$default")"
	if [[ -t 0 ]]; then
		# Auto-detect: if default path is a valid install, offer to use it
		if [[ -d "$default" ]] && [[ -f "${default}/docker-compose.yml" ]] && [[ -f "${default}/telemt.toml" ]]; then
			if prompt_yes_no "Найден каталог установки: ${default}. Использовать?" "y"; then
				echo "$default"
				return 0
			fi
		fi
		while true; do
			input=$(prompt_input "Каталог установки (q — отмена)" "$default")
			if [[ -z "$input" ]]; then input="$default"; fi
			input_trimmed=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
			if [[ "$input_trimmed" == "q" ]] || [[ "$input_trimmed" == "quit" ]] || [[ "$input_trimmed" == "отмена" ]] || [[ "$input_trimmed" == "cancel" ]] || [[ "$input_trimmed" == "exit" ]]; then
				echo "CANCEL"
				return 0
			fi
			local dir
			dir="$(resolve_install_dir "$input")"
			if [[ ! -d "$dir" ]]; then
				show_warning "Каталог не найден: ${dir}. Введите другой путь или q для отмены."
				if [[ -n "$offer_install" ]]; then
					if prompt_yes_no "Выполнить новую установку в этот каталог?" "n"; then
						echo "INSTALL:${dir}"
						return 0
					fi
				fi
				continue
			fi
			if [[ ! -f "${dir}/docker-compose.yml" ]] || [[ ! -f "${dir}/telemt.toml" ]]; then
				show_warning "Не похоже на установку telemt. Укажите другой каталог или q для отмены."
				continue
			fi
			echo "$dir"
			return 0
		done
	fi
	echo "$default"
}

# --- Команды ---
cmd_install() {
	INSTALL_DIR="$(resolve_install_dir "$INSTALL_DIR")"

	draw_section_header "Установка MTpannel" "$BOX_WIDTH"
	show_info "Каталог: ${INSTALL_DIR}"
	echo ""

	check_docker

	if [[ -n "${INSTALL_DIR_FROM_ENV}" ]]; then
		INSTALL_DIR="${INSTALL_DIR_FROM_ENV}"
	else
		if [[ -t 0 ]]; then
			local input
			input=$(prompt_input "Каталог установки" "$INSTALL_DIR")
			if [[ -n "$input" ]]; then INSTALL_DIR="$input"; fi
			INSTALL_DIR="$(resolve_install_dir "$INSTALL_DIR")"
		fi
	fi

	# If directory already has an installation, offer to update instead
	if [[ -d "$INSTALL_DIR" ]] && [[ -f "${INSTALL_DIR}/docker-compose.yml" ]] && [[ -f "${INSTALL_DIR}/telemt.toml" ]] && [[ -t 0 ]]; then
		show_info "В каталоге уже есть установка: ${INSTALL_DIR}"
		if prompt_yes_no "Обновить (перейти в обновление)?" "y"; then
			cmd_update "$INSTALL_DIR"
			return 0
		fi
	fi

	# Порт
	if [[ -n "${LISTEN_PORT}" ]] && [[ "${LISTEN_PORT}" != "443" ]] && [[ ! -t 0 ]]; then
		:
	elif [[ -t 0 ]]; then
		local suggested=443
		if is_port_in_use 443; then
			show_warning "Порт 443 занят."
			suggested=1443
		fi
		while true; do
			local port_input
			port_input=$(prompt_input "Порт для прокси" "$suggested")
			if [[ -z "$port_input" ]]; then port_input=$suggested; fi
			if [[ "$port_input" =~ ^[0-9]+$ ]] && (( port_input >= 1 && port_input <= 65535 )); then
				if is_port_in_use "$port_input"; then
					show_warning "Порт ${port_input} занят."
				else
					LISTEN_PORT=$port_input
					break
				fi
			else
				show_warning "Введите число от 1 до 65535."
			fi
		done
	else
		LISTEN_PORT="${LISTEN_PORT:-443}"
	fi

	# Домен SNI
	if [[ -n "${FAKE_DOMAIN_FROM_ENV}" ]]; then
		FAKE_DOMAIN="${FAKE_DOMAIN_FROM_ENV}"
	elif [[ -t 0 ]]; then
		local domain_input
		domain_input=$(prompt_input "Домен для маскировки Fake TLS (SNI)" "$FAKE_DOMAIN")
		if [[ -n "$domain_input" ]]; then FAKE_DOMAIN="$domain_input"; fi
	fi

	# Подтверждение
	if [[ -t 0 ]]; then
		draw_separator "$BOX_WIDTH" "$BOX_LINE"
		draw_info_row "Каталог" "${INSTALL_DIR}"
		draw_info_row "Порт" "${LISTEN_PORT}"
		draw_info_row "Домен SNI" "${FAKE_DOMAIN}"
		draw_separator "$BOX_WIDTH" "$BOX_LINE"
		if ! prompt_yes_no "Продолжить установку?" "y"; then
			show_info "Установка отменена."
			return 0
		fi
	fi

	# Образ: 1 — готовый (по умолчанию), 2 — сборка из исходников
	if [[ -t 0 ]]; then
		draw_menu_options "Скачать готовый образ (${TELEMT_PREBUILT_IMAGE})" "Собрать из исходников (локально)"
		printf '%s (1-2) [1]: ' "${GREEN}Выбор${NC}" >&2
		read -r img_choice || true
		printf '\n' >&2
		img_choice="${img_choice%% *}"
		if [[ "$img_choice" == "2" ]]; then
			TELEMT_IMAGE_SOURCE=build
		else
			TELEMT_IMAGE_SOURCE=prebuilt
		fi
	else
		TELEMT_IMAGE_SOURCE="${TELEMT_IMAGE_SOURCE:-prebuilt}"
	fi

	if [[ "$TELEMT_IMAGE_SOURCE" == "build" ]]; then
		if ! is_build_repo_root "$REPO_ROOT"; then
			ensure_git
			mkdir -p "${INSTALL_DIR}"
			CLONE_DIR="${INSTALL_DIR}/.telemt-source"
			if [[ -d "${CLONE_DIR}/.git" ]]; then
				show_info "Обновляю клон репозитория в ${CLONE_DIR} ..."
				(cd "${CLONE_DIR}" && git pull --depth 1 2>/dev/null) || true
			else
				show_info "Клонирую GrandMax/telemt-pannel в ${CLONE_DIR} ..."
				git clone --depth 1 https://github.com/GrandMax/telemt-pannel.git "${CLONE_DIR}"
			fi
			REPO_ROOT="${CLONE_DIR}"
		fi
	fi

	copy_and_configure
	run_compose
	print_link
}

# Check for newer install.sh/mtpannel.sh and replace if running from repo root with write access.
update_scripts_if_newer() {
	show_info "Проверка новой версии скриптов в репозитории (SCRIPT_VERSION)..."
	[[ -d "${REPO_ROOT}/install" ]] || return 0
	[[ -f "${REPO_ROOT}/install.sh" ]] && [[ -f "${REPO_ROOT}/mtpannel.sh" ]] || return 0
	[[ -w "${REPO_ROOT}/install.sh" ]] && [[ -w "${REPO_ROOT}/mtpannel.sh" ]] || return 0

	local current="${SCRIPT_VERSION:-}"
	local remote_ver=""
	if [[ -d "${REPO_ROOT}/.git" ]]; then
		(cd "${REPO_ROOT}" && git fetch origin 2>/dev/null) || true
		remote_ver=$(cd "${REPO_ROOT}" && git show origin/HEAD:install.sh 2>/dev/null | head -25 | grep -E '^SCRIPT_VERSION="' | head -1 | sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p')
	fi
	if [[ -z "$remote_ver" ]]; then
		remote_ver=$(curl -sL "https://raw.githubusercontent.com/GrandMax/telemt-pannel/main/install.sh" 2>/dev/null | head -25 | grep -E '^SCRIPT_VERSION="' | head -1 | sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p')
	fi
	[[ -n "$remote_ver" ]] || return 0

	local latest
	latest=$(printf '%s\n' "$current" "$remote_ver" | sort -V | tail -1)
	if [[ "$latest" != "$remote_ver" ]] || [[ "$current" == "$remote_ver" ]]; then
		show_info "Версия скриптов актуальна (${current})."
		return 0
	fi

	if [[ -d "${REPO_ROOT}/.git" ]] && (cd "${REPO_ROOT}" && git show origin/HEAD:install.sh &>/dev/null); then
		(cd "${REPO_ROOT}" && git checkout origin/HEAD -- install.sh mtpannel.sh 2>/dev/null) && show_success "Скрипты обновлены до версии ${remote_ver}."
	else
		local ok=1
		if curl -sL -o "${REPO_ROOT}/install.sh.new" "https://raw.githubusercontent.com/GrandMax/telemt-pannel/main/install.sh" 2>/dev/null; then
			mv "${REPO_ROOT}/install.sh.new" "${REPO_ROOT}/install.sh" && chmod +x "${REPO_ROOT}/install.sh" || ok=0
		else
			ok=0
		fi
		if [[ $ok -eq 1 ]] && curl -sL -o "${REPO_ROOT}/mtpannel.sh.new" "https://raw.githubusercontent.com/GrandMax/telemt-pannel/main/mtpannel.sh" 2>/dev/null; then
			mv "${REPO_ROOT}/mtpannel.sh.new" "${REPO_ROOT}/mtpannel.sh" && chmod +x "${REPO_ROOT}/mtpannel.sh" && show_success "Скрипты обновлены до версии ${remote_ver}."
		else
			[[ $ok -eq 1 ]] || show_warning "Не удалось загрузить новые версии скриптов."
		fi
	fi
}

cmd_update() {
	show_info "Обновление (Docker: pull или пересборка и перезапуск)..."
	local dir result
	if [[ $# -gt 0 ]]; then
		dir="$(resolve_install_dir "${1}")"
	else
		show_info "Укажите каталог установки."
		result="$(prompt_install_dir_existing "${INSTALL_DIR}" "offer")"
		if [[ "$result" == INSTALL:* ]]; then
			INSTALL_DIR="${result#INSTALL:}"
			cmd_install
			return
		fi
		if [[ "$result" == "CANCEL" ]]; then
			show_info "Отменено."
			return
		fi
		dir="$result"
	fi
	if [[ ! -d "$dir" ]] || [[ ! -f "${dir}/docker-compose.yml" ]] || [[ ! -f "${dir}/telemt.toml" ]]; then
		err "Не похоже на установку telemt: ${dir}"
	fi
	show_info "Каталог: ${dir}"
	update_scripts_if_newer
	local img_source=build
	if [[ -f "${dir}/.env" ]]; then
		local val
		val=$(grep -E '^TELEMT_IMAGE_SOURCE=' "${dir}/.env" 2>/dev/null | cut -d= -f2-)
		if [[ -n "$val" ]]; then img_source="$val"; fi
	fi
	if [[ "$img_source" == "prebuilt" ]]; then
		show_info "Скачиваю образ (pull)..."
		(cd "$dir" && docker compose --progress plain pull telemt)
		show_info "Перезапускаю контейнеры..."
		(cd "$dir" && docker compose up -d)
	else
		show_info "Пересборка образа (build)..."
		(cd "$dir" && docker compose build telemt)
		show_info "Перезапускаю контейнеры..."
		(cd "$dir" && docker compose up -d)
	fi
	show_success "Готово."
	INSTALL_DIR="$dir"
	print_link
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
		show_info "Укажите каталог установки."
		local result
		result="$(prompt_install_dir_existing "${INSTALL_DIR}" "offer")"
		if [[ "$result" == INSTALL:* ]]; then
			INSTALL_DIR="${result#INSTALL:}"
			cmd_install
			return
		fi
		if [[ "$result" == "CANCEL" ]]; then
			show_info "Отменено."
			return
		fi
		dir="$result"
	fi

	if [[ ! -f "${dir}/telemt.toml" ]] || [[ ! -f "${dir}/traefik/dynamic/tcp.yml" ]]; then
		err "Каталог установки не найден или неполный: ${dir}"
	fi
	show_info "Каталог: ${dir}"

	local current_domain
	current_domain=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${dir}/telemt.toml" | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')

	if [[ -z "$new_domain" ]]; then
		if [[ -t 0 ]]; then
			draw_section_header "Смена домена (SNI)" "$BOX_WIDTH"
			draw_info_row "Текущий домен" "$current_domain"
			new_domain=$(prompt_input "Новый домен для Fake TLS (tls_domain)" "$current_domain")
			if [[ -z "$new_domain" ]]; then new_domain="$current_domain"; fi
		else
			err "Без TTY укажите домен: FAKE_DOMAIN=... или mtpannel.sh config --sni example.com"
		fi
	fi

	if [[ -z "$new_domain" ]]; then err "Домен не задан."; fi

	sed -i.bak -E "s/^([[:space:]]*tls_domain[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"${new_domain}\"/" "${dir}/telemt.toml"
	rm -f "${dir}/telemt.toml.bak"

	local tcp_yml="${dir}/traefik/dynamic/tcp.yml"
	NEW_DOMAIN="$new_domain" perl -i -pe 's/HostSNI\(`[^`]*`\)/HostSNI(`$ENV{NEW_DOMAIN}`)/' "$tcp_yml" 2>/dev/null || {
		if sed --version 2>/dev/null | grep -q GNU; then
			sed -i "s/HostSNI(\`[^\`]*\`)/HostSNI(\`${new_domain}\`)/" "$tcp_yml"
		else
			sed -i '' "s/HostSNI(\`[^\`]*\`)/HostSNI(\`${new_domain}\`)/" "$tcp_yml"
		fi
	}

	show_success "Домен обновлён на ${new_domain}."
	show_info "Перезапускаю контейнеры..."
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
		show_info "Укажите каталог установки для удаления."
		dir="$(prompt_install_dir_existing "${INSTALL_DIR}")"
		if [[ "$dir" == "CANCEL" ]]; then
			show_info "Отменено."
			return 0
		fi
	else
		dir="$(resolve_install_dir "${dir:-$INSTALL_DIR}")"
	fi

	if [[ ! -d "$dir" ]]; then
		err "Каталог не найден: ${dir}"
	fi
	if [[ ! -f "${dir}/docker-compose.yml" ]] || [[ ! -f "${dir}/telemt.toml" ]]; then
		err "Не похоже на установку telemt: ${dir}"
	fi
	show_info "Каталог: ${dir}"

	# Собрать список образов до любых деструктивных действий
	local uninstall_images
	uninstall_images=$(grep -E '^[[:space:]]+image:[[:space:]]+' "${dir}/docker-compose.yml" 2>/dev/null | sed -E 's/^[[:space:]]*image:[[:space:]]*["]?([^"]+)["]?.*/\1/' | tr -d ' \r' | sort -u || true)
	uninstall_images=$(printf '%s' "$uninstall_images" | grep -v '^$' || true)

	if [[ -z "$force" ]] && [[ -t 0 ]]; then
		draw_section_header "Удаление установки" "$BOX_WIDTH"
		draw_info_row "Каталог" "$dir"
		echo ""
		if ! prompt_yes_no "Удалить установку?" "y"; then
			show_info "Отменено."
			return 0
		fi
	fi

	show_info "Выполняю: docker compose down -v (каталог: ${dir})"
	(cd "$dir" && docker compose down -v) || true
	show_info "Контейнеры и тома удалены."

	if [[ -n "$uninstall_images" ]] && [[ -t 0 ]]; then
		echo ""
		show_info "Образы Docker, использовавшиеся установкой:"
		printf '%s\n' "$uninstall_images" | while read -r img; do [[ -n "$img" ]] && echo "  - $img"; done
		show_warning "Образ traefik может использоваться другими проектами."
		if prompt_yes_no "Удалить эти образы?" "n"; then
			local removed=0
			while IFS= read -r img; do
				[[ -z "$img" ]] && continue
				show_info "Удаляю образ: ${img}"
				if docker rmi "$img" 2>/dev/null; then removed=$((removed + 1)); else show_warning "Не удалось удалить образ: $img"; fi
			done <<< "$uninstall_images"
			[[ $removed -gt 0 ]] && show_info "Образы удалены."
		fi
		echo ""
	fi

	show_info "Удаляю каталог ${dir} ..."
	rm -rf "$dir"
	show_success "Готово."
}

# --- Главное меню ---
show_main_menu() {
	draw_section_header "MTpannel" "$BOX_WIDTH"
	draw_menu_options \
		"Установка (новая установка в каталог)" \
		"Обновление (Docker: pull или пересборка и перезапуск)" \
		"Смена домена (SNI)" \
		"Удаление" \
		"Выход"
	prompt_menu_option "Выберите действие" 1 5
}

usage() {
	echo "Использование: $0 [install | update | config | uninstall] [опции]"
	echo ""
	echo "  Без аргументов (при TTY): интерактивное меню с псевдографикой."
	echo "  С аргументом — параметры из env: INSTALL_DIR, LISTEN_PORT, FAKE_DOMAIN и т.д."
	echo ""
	echo "  install   — установка"
	echo "  update    — обновление образа и перезапуск"
	echo "  config    — смена домена Fake TLS (SNI); без TTY: --sni DOMAIN"
	echo "  uninstall — удаление; -y для подтверждения без запроса"
	exit 0
}

main() {
	if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
		usage
	fi

	if [[ $# -eq 0 ]] && [[ -t 0 ]]; then
		check_docker
		while true; do
			clear_screen
			draw_section_header "MTpannel" "$BOX_WIDTH"
			draw_menu_options \
				"Установка (новая установка в каталог)" \
				"Обновление (Docker: pull или пересборка и перезапуск)" \
				"Смена домена (SNI)" \
				"Удаление" \
				"Выход"
			choice=$(prompt_menu_option "Выберите действие" 1 5)
			case "$choice" in
				1) cmd_install; printf '\n'; printf 'Нажмите Enter для возврата в меню...'; read -r || true ;;
				2) cmd_update; printf '\n'; printf 'Нажмите Enter для возврата в меню...'; read -r || true ;;
				3) cmd_config; printf '\n'; printf 'Нажмите Enter для возврата в меню...'; read -r || true ;;
				4) cmd_uninstall; printf '\n'; printf 'Нажмите Enter для возврата в меню...'; read -r || true ;;
				5) show_success "Выход."; exit 0 ;;
				*) ;;
			esac
		done
		return 0
	fi

	local cmd="${1:-install}"
	if [[ $# -gt 0 ]]; then shift; fi
	case "$cmd" in
		install)  cmd_install "$@" ;;
		update)   cmd_update "$@" ;;
		config)   cmd_config "$@" ;;
		uninstall) cmd_uninstall "$@" ;;
		*) err "Неизвестная подкоманда: $cmd. Без аргументов — меню, иначе: install | update | config | uninstall" ;;
	esac
}

main "$@"
