#!/usr/bin/env bash
#
# linux-auto-install.sh — установка zapret2 на Яндекс Станцию с ПК под Linux.
#
# Скрипт подключается к колонке по ADB (порт 5555), копирует во временный
# каталог /data/tmp/zapret2-install/ файлы из папки files/ и запускает на
# станции install.sh.
#
# Запуск:
#   ./linux-auto-install.sh
#
# Требуется adb (android-tools / adb в PATH) либо путь к нему будет запрошен.

set -u

# ---- Оформление -------------------------------------------------------------
LOGO='
▐▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▌
▐  █████╗ ██╗     ██╗ ██████╗███████╗                       ▌
▐ ██╔══██╗██║     ██║██╔════╝██╔════╝                       ▌
▐ ███████║██║     ██║██║     █████╗                         ▌
▐ ██╔══██║██║     ██║██║     ██╔══╝                         ▌
▐ ██║  ██║███████╗██║╚██████╗███████╗                       ▌
▐ ╚═╝  ╚═╝╚══════╝╚═╝ ╚═════╝╚══════╝                       ▌
▐                                                           ▌
▐ ███████╗ █████╗ ██████╗ ██████╗ ███████╗████████╗██████╗  ▌
▐ ╚══███╔╝██╔══██╗██╔══██╗██╔══██╗██╔════╝╚══██╔══╝╚════██╗ ▌
▐   ███╔╝ ███████║██████╔╝██████╔╝█████╗     ██║    █████╔╝ ▌
▐  ███╔╝  ██╔══██║██╔═══╝ ██╔══██╗██╔══╝     ██║   ██╔═══╝  ▌
▐ ███████╗██║  ██║██║     ██║  ██║███████╗   ██║   ███████╗ ▌
▐ ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝ ▌
▐▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▌
'

C_INFO='\033[36m'
C_SUCCESS='\033[32m'
C_WARN='\033[33m'
C_ERROR='\033[31m'
C_ACTION='\033[35m'
C_WHITE='\033[97m'
C_RESET='\033[0m'

show_log() {
    local type="$1"
    local message="$2"
    local prefix pcolor mcolor

    case "$type" in
        INFO)    prefix=' [i] [INFO]    '; pcolor="$C_INFO";    mcolor="$C_WHITE" ;;
        SUCCESS) prefix=' [+] [SUCCESS] '; pcolor="$C_SUCCESS"; mcolor="$C_SUCCESS" ;;
        WARN)    prefix=' [!] [WARN]    '; pcolor="$C_WARN";    mcolor="$C_WARN" ;;
        ERROR)   prefix=' [-] [ERROR]   '; pcolor="$C_ERROR";   mcolor="$C_ERROR" ;;
        ACTION)  prefix=' [>] [ACTION]  '; pcolor="$C_ACTION";  mcolor="$C_WHITE" ;;
        INPUT)   prefix=' [?] [INPUT]   '; pcolor="$C_ACTION";  mcolor="$C_WHITE" ;;
        OK)      prefix=' [✓] [OK]      '; pcolor="$C_SUCCESS"; mcolor="$C_SUCCESS" ;;
        *)       prefix=' [i] [INFO]    '; pcolor="$C_INFO";    mcolor="$C_WHITE" ;;
    esac

    printf '%b%s%b%b%s%b\n' "$pcolor" "$prefix" "$C_RESET" "$mcolor" "$message" "$C_RESET"
}

prompt_yes_no() {
    local question="$1"
    local default="$2"
    local answer hint

    if [ "$default" = "yes" ]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    while true; do
        printf '%b [?] [INPUT]   %b%b%s %b' "$C_ACTION" "$C_RESET" "$C_WHITE" "$question" "$C_RESET"
        if ! read -r answer; then
            echo
            return 1
        fi
        answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
        case "$answer" in
            '') [ "$default" = "yes" ] && return 0 || return 1 ;;
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
            *) show_log ERROR "Ответьте 'y' (да) или 'n' (нет)." ;;
        esac
    done
}

# ---- Приветствие ------------------------------------------------------------
printf '%b%s%b\n' "$C_SUCCESS" "$LOGO" "$C_RESET"

show_log INFO "Скрипт подключится к вашей колонке по ADB и установит всё необходимое."
show_log WARN "ПРОВЕРЕНО ТОЛЬКО НА ЯНДЕКС СТАНЦИЯ МИНИ 2."

if ! prompt_yes_no "Вы хотите продолжить выполнение скрипта?" yes; then
    show_log ERROR "Установка отменена пользователем. Выход..."
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCAL_PATH="$SCRIPT_DIR/files"
REMOTE_PATH="/data/tmp/zapret2-install/"
FILES_TO_COPY=(
    "install.sh"
    "start.sh"
    "stop.sh"
    "hosts.txt"
    "S99zapret2"
)

installation() {
    local adb_path="adb"
    local alice_ip=""
    local input_ip input_path clean_path file file_name
    local devices_output is_connected line install_exit_code

    show_log ACTION "Проверяю наличие ADB в системе..."
    if ! command -v adb >/dev/null 2>&1; then
        show_log WARN "ADB не найден в системном PATH."

        while true; do
            printf '%b [?] [INPUT]   %b%bУкажите полный путь к исполняемому файлу adb: %b' "$C_ACTION" "$C_RESET" "$C_WHITE" "$C_RESET"
            if ! read -r input_path; then
                echo
                show_log ERROR "Ввод прерван."
                return 1
            fi
            clean_path=$(printf '%s' "$input_path" | sed -e 's/^"//' -e 's/"$//')

            if [ -f "$clean_path" ] && [ -x "$clean_path" ]; then
                adb_path="$clean_path"
                break
            elif [ -f "$clean_path/adb" ] && [ -x "$clean_path/adb" ]; then
                adb_path="$clean_path/adb"
                break
            else
                show_log ERROR "Файл adb не найден по указанному пути. Попробуйте еще раз."
            fi
        done
    fi

    for file in "${FILES_TO_COPY[@]}"; do
        if [ ! -f "$LOCAL_PATH/$file" ]; then
            show_log ERROR "Файлы не найдены на ПК: $file"
            show_log WARN "Убедитесь, что папка 'files' находится рядом со скриптом и содержит все компоненты."
            return 1
        fi
    done

    while true; do
        printf '%b [?] [INPUT]   %b%bВведите IP-адрес вашей Яндекс Станции: %b' "$C_ACTION" "$C_RESET" "$C_WHITE" "$C_RESET"
        if ! read -r input_ip; then
            echo
            show_log ERROR "Ввод прерван."
            return 1
        fi
        input_ip=$(printf '%s' "$input_ip" | tr -d '[:space:]')

        if [ -z "$input_ip" ]; then
            show_log ERROR "IP-адрес не может быть пустым!"
            continue
        fi

        if printf '%s' "$input_ip" | grep -Eq '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'; then
            alice_ip="$input_ip"
            break
        else
            show_log ERROR "Неверный формат IP! Пример правильного: 192.168.1.50"
        fi
    done

    show_log OK "IP-адрес принят: $alice_ip"
    show_log ACTION "Подготовка к переносу файлов..."

    show_log INFO "Подключаюсь к станции по ADB ($alice_ip)..."
    "$adb_path" connect "${alice_ip}:5555" >/dev/null 2>&1

    sleep 1

    devices_output=$("$adb_path" devices 2>/dev/null)
    is_connected=0

    while IFS= read -r line; do
        if printf '%s' "$line" | grep -Eq "^${alice_ip//./\\.}(:[0-9]+)?[[:space:]]+device$"; then
            is_connected=1
            break
        fi
    done <<EOF
$devices_output
EOF

    if [ "$is_connected" -eq 0 ]; then
        show_log ERROR "Не удалось установить ADB-соединение с $alice_ip!"
        show_log WARN "Убедитесь, что:"
        show_log WARN "  1. Указан правильный IP-адрес."
        show_log WARN "  2. Колонка включена и находится в одной сети с ПК."
        show_log WARN "  3. На станции включен режим отладки (ADB)."
        return 1
    fi

    show_log SUCCESS "Успешное подключение к Яндекс Станции!"

    show_log INFO "Создаю временную папку на Станции..."
    "$adb_path" shell "mkdir -p $REMOTE_PATH"

    show_log ACTION "Переношу файлы через ADB..."
    for file in "${FILES_TO_COPY[@]}"; do
        file_name=$(basename "$file")
        "$adb_path" push "$LOCAL_PATH/$file" "$REMOTE_PATH$file_name"
    done

    if [ $? -eq 0 ]; then
        show_log SUCCESS "Все файлы успешно перенесены через ADB!"
    else
        show_log ERROR "Ошибка при передаче файлов через ADB."
        return 1
    fi

    show_log ACTION "Запускаю установочный скрипт на Станции..."
    show_log INFO "Выдаю права на выполнение и запускаю install.sh..."

    "$adb_path" shell "chmod +x ${REMOTE_PATH}install.sh && ${REMOTE_PATH}install.sh"
    install_exit_code=$?

    if prompt_yes_no "Хотите удалить установочный скрипт с колонки?" yes; then
        show_log ACTION "Очищаю временную папку на колонке..."
        "$adb_path" shell "rm -rf $REMOTE_PATH"

        if [ $? -eq 0 ]; then
            show_log SUCCESS "Временные файлы на колонке успешно удалены."
        else
            show_log WARN "Не удалось удалить временные файлы на колонке."
        fi
    else
        show_log INFO "Очистка отменена. Временные файлы сохранены в $REMOTE_PATH"
    fi

    if [ "$install_exit_code" -eq 0 ]; then
        show_log SUCCESS "Скрипт на колонке отработал успешно!"
    else
        show_log ERROR "Произошла ошибка при выполнении install.sh на стороне Станции."
    fi
}

show_log ACTION "Запуск процесса установки..."
installation
exit $?
