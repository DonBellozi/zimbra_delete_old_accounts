#!/bin/bash
# delete_old_accounts.sh - Автоматическая очистка старых почтовых ящиков Zimbra
#
# Copyright (c) 2025 Ivan V. Belikov
#
# Лицензия: MIT License (см. файл LICENSE)
# https://opensource.org/licenses/MIT
# ------------------------------------------------------------
# Скрипт очистки старых почтовых ящиков Zimbra.
#
# Что делает:
# 1) Читает CSV /opt/zimbra/accounts_with_date.csv
#    Формат строк: Email;Дата создания;Статус;Notes;Последний вход;DisplayName
# 2) Читает файл исключений /opt/zimbra/logs/tmp/actual_email TXT.txt
#    - 1-я строка заголовок (игнорируется)
#    - возможны пустые строки (игнорируются)
#    - в строке может быть несколько email с любыми разделителями
#    - все найденные email попадают в список EXCLUDES
# 3) Для каждого ящика:
#    - пропускает, если email в EXCLUDES
#    - пропускает, если notes содержит never_disable
#    - если last_login пустой → смотрит дату создания
#    - если last_login есть → обрабатывает только status=closed
#    - при давности > 1 года делает бэкап в /opt/tmp/<email>-YYYYMMDD.tgz
#    - если бэкап успешный → удаляет ящик (или только логирует при --dry-run)
#
# Логи:
#   /opt/zimbra/logs/delete_old_accounts.log
#   /opt/zimbra/logs/delete_old_accounts_dryrun.log
# Отчёт:
#   /opt/zimbra/logs/deleted_accounts_report.log (email;DD.MM.YYYY)
#
# Запуск:
#   ./delete_old_accounts.sh
#   ./delete_old_accounts.sh --dry-run
# ------------------------------------------------------------

# -----------------------------
# Переменные окружения
# -----------------------------
export PATH="/opt/zimbra/bin:/usr/bin:/bin:/opt/zimbra/common/bin"
export LANG="ru_RU.UTF-8"
export LC_ALL="ru_RU.UTF-8"

# Флаг dry-run
DRYRUN=false
[[ "$1" == "--dry-run" ]] && DRYRUN=true

# -----------------------------
# Пути
# -----------------------------
CSV_FILE="/opt/zimbra/accounts_with_date.csv"
BACKUP_DIR="/opt/tmp"
LOG_DIR="/opt/zimbra/logs"

# Файл исключений (важно: в имени есть пробелы)
EXCLUDE_FILE="/opt/zimbra/logs/tmp/actual_email TXT.txt"

# -----------------------------
# Логи: отдельный для dry-run
# -----------------------------
if $DRYRUN; then
    LOGFILE="${LOG_DIR}/delete_old_accounts_dryrun.log"
else
    LOGFILE="${LOG_DIR}/delete_old_accounts.log"
fi
REPORT_FILE="${LOG_DIR}/deleted_accounts_report.log"

# Подготовка директорий
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# Очистка логов и отчёта (каждый запуск — свежий лог)
#> "$LOGFILE"
#> "$REPORT_FILE"

# Логи и отчёт накапливаем (append), ничего не очищаем
touch "$LOGFILE" "$REPORT_FILE"

# (Опционально) Очистка резервных копий — по умолчанию отключена.
# Включи, если нужно: раскомментируй 2 строки ниже.
# echo "[$(date)] Очистка каталога $BACKUP_DIR" >> "$LOGFILE"
# rm -f "$BACKUP_DIR"/*.tgz 2>> "$LOGFILE"

# -----------------------------
# Порог давности (1 год)
# -----------------------------
ONE_YEAR_AGO=$(date -d "1 years ago" +"%s")
NOW_DATE=$(date +"%d.%m.%Y")
NOW_FILENAME=$(date +"%Y%m%d")

echo "[$(date)] === Запуск удаления (dry-run=$DRYRUN) ===" >> "$LOGFILE"

# -----------------------------
# Проверяем наличие CSV
# -----------------------------
if [[ ! -f "$CSV_FILE" ]]; then
    echo "[$(date)] ERROR: CSV-файл не найден: $CSV_FILE" >> "$LOGFILE"
    exit 1
fi

# -----------------------------
# Загрузка исключений
# -----------------------------
declare -A EXCLUDES

load_exclusions() {
    EXCLUDES=()  # очищаем на всякий случай

    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        echo "[$(date)] WARN: файл исключений не найден: $EXCLUDE_FILE" >> "$LOGFILE"
        return 0
    fi

    # читаем со 2-й строки (заголовок пропускаем)
    # в каждой строке вытаскиваем ВСЕ email-ы regex'ом
    while IFS= read -r raw_line; do
        # raw_line может быть пустой — тогда emails пустой
        emails=$(echo "$raw_line" | grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}')

        if [[ -n "$emails" ]]; then
            while IFS= read -r e; do
                e=$(echo "$e" | tr '[:upper:]' '[:lower:]')
                EXCLUDES["$e"]=1
            done <<< "$emails"
        fi
        # пустые строки просто игнорируются
    done < <(tail -n +2 "$EXCLUDE_FILE")

    echo "[$(date)] Загружено исключений: ${#EXCLUDES[@]}" >> "$LOGFILE"
}

load_exclusions

# -----------------------------
# Обработка CSV
# Структура фиксированная:
# Email;Дата создания;Статус;Notes;Последний вход;DisplayName
# -----------------------------
tail -n +2 "$CSV_FILE" | while read -r line; do
    # Извлекаем поля строго по номерам (cut) — безопасно при пробелах в полях
    email=$(echo "$line" | cut -d ';' -f1 | tr -d '[:space:]')
    created_raw=$(echo "$line" | cut -d ';' -f2)
    status=$(echo "$line" | cut -d ';' -f3 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    notes=$(echo "$line" | cut -d ';' -f4 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    last_login_raw=$(echo "$line" | cut -d ';' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # displayname=$(echo "$line" | cut -d ';' -f6)

    # --- Пропуск, если email в списке исключений ---
    email_lc=$(echo "$email" | tr '[:upper:]' '[:lower:]')
    if [[ -n "${EXCLUDES[$email_lc]}" ]]; then
        echo "$email — пропущен (в файле исключений)" >> "$LOGFILE"
        continue
    fi

    # Пропуск по never_disable в любом случае
    if [[ "$notes" == *never_disable* ]]; then
        echo "$email — пропущен (never_disable)" >> "$LOGFILE"
        continue
    fi

    # Нормализация дат:
    # created_raw: может быть 20161007172147Z или 20161007172147.846Z
    # last_login_raw: может быть "YYYY-MM-DD hh:mm:ss" или пусто
    clean_created_yyyymmdd=$(echo "$created_raw" | sed -E 's/^([0-9]{8}).*/\1/')
    clean_last_login=$(echo "$last_login_raw" | sed -E 's/\.[0-9]+Z$//; s/Z$//')

    # --- Сценарий A: Нет последнего входа => ориентируемся на дату создания ---
    if [[ -z "$clean_last_login" ]]; then
        created_fmt=$(date -d "${clean_created_yyyymmdd}" +"%Y-%m-%d" 2>/dev/null)
        created_ts=$(date -d "$created_fmt" +%s 2>/dev/null)

        if [[ -z "$created_ts" ]]; then
            echo "$email — ошибка разбора даты создания: $created_raw" >> "$LOGFILE"
            continue
        fi

        if (( created_ts >= ONE_YEAR_AGO )); then
            echo "$email — создан менее 1 года назад ($created_fmt), пропущен" >> "$LOGFILE"
            continue
        fi

        echo "$email — входов не было, но создан до $created_fmt, готовим резервную копию" >> "$LOGFILE"

    else
        # --- Сценарий B: Есть последний вход => только если status == closed ---
        if [[ "$status" != "closed" ]]; then
            echo "$email — пропущен (статус: $status)" >> "$LOGFILE"
            continue
        fi

        # last_login может быть в формате YYYY-MM-DD hh:mm:ss — берём дату
        if [[ "$clean_last_login" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
            login_date_part=$(echo "$clean_last_login" | awk '{print $1}')
            login_ts=$(date -d "$login_date_part" +%s 2>/dev/null)
            login_fmt="$login_date_part"
        else
            # Если last_login в формате 20240730105430 или 20240730105430.398Z (без тире)
            login_yyyymmdd=$(echo "$clean_last_login" | sed -E 's/^([0-9]{8}).*/\1/')
            login_fmt=$(date -d "${login_yyyymmdd}" +"%Y-%m-%d" 2>/dev/null)
            login_ts=$(date -d "$login_fmt" +%s 2>/dev/null)
        fi

        if [[ -z "$login_ts" ]]; then
            echo "$email — ошибка разбора даты входа: $last_login_raw" >> "$LOGFILE"
            continue
        fi

        if (( login_ts >= ONE_YEAR_AGO )); then
            echo "$email — активен после $login_fmt, пропущен" >> "$LOGFILE"
            continue
        fi

        echo "$email — последний вход до $login_fmt, готовим резервную копию" >> "$LOGFILE"
    fi

    # --- Резервная копия: создаём архив и проверяем, что он непустой ---
    backup_file="${BACKUP_DIR}/${email}-${NOW_FILENAME}.tgz"
    zmmailbox -z -m "$email" getRestURL "//?fmt=tgz" > "$backup_file" 2>> "$LOGFILE"

    # Если файл непустой — считаем, что бэкап создан корректно
    if [[ -s "$backup_file" ]]; then
        echo "$email — резервная копия создана: $backup_file" >> "$LOGFILE"

        # Простая валидация email
        if [[ -z "$email" || ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$ ]]; then
            echo "$email — ошибка: некорректный email, удаление отменено" >> "$LOGFILE"
            rm -f "$backup_file"
            continue
        fi

        if $DRYRUN; then
            echo "$email — [dry-run] удаление пропущено" >> "$LOGFILE"
        else
            # Удаляем аккаунт
            zmprov da "$email" &>> "$LOGFILE"
            if [[ $? -eq 0 ]]; then
                echo "$email — удалён" >> "$LOGFILE"
            else
                echo "$email — ошибка удаления (см. выше)" >> "$LOGFILE"
                # при ошибке удаления бэкап оставляем
            fi
        fi

        # Запись в отчёт (формат: email;DD.MM.YYYY)
        echo "${email};${NOW_DATE}" >> "$REPORT_FILE"

    else
        echo "$email — резервная копия не создана или пуста (возможно, ящик не существует)" >> "$LOGFILE"
        rm -f "$backup_file" 2>/dev/null
    fi

done

echo "[$(date)] === Завершено ===" >> "$LOGFILE"
