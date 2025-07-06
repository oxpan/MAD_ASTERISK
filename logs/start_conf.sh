#!/bin/bash
# Настройки
CONF_NUMBER="900"                     # Номер конференции
PEERS=("100" "101" "102" "103" "104" "105" "106")             # Список абонентов
LOCK_FILE="/tmp/conf_${CONF_NUMBER}.lock"
LOG_FILE="/var/log/asterisk/conf_${CONF_NUMBER}.log"
CALLER_ID="Конференция <${CONF_NUMBER}>"
MAX_ATTEMPTS=3                        # Максимальное количество попыток дозвона
RETRY_DELAY=15                        # Задержка между волнами (секунды)
MONITOR_INTERVAL=5                    # Интервал проверки активности (секунды)
GRACE_PERIOD=30                       # Время ожидания после выхода последнего участника (секунды)

# Глобальные переменные для статистики
declare -A PARTICIPANT_STATS           # Статистика по участникам
declare -A CURRENT_PARTICIPANTS        # Текущие участники
CONF_START_TIME=$(date +%s)           # Время старта конференции
LAST_ACTIVITY_TIME=$(date +%s)        # Время последней активности

# Функции #################################################################

log_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

is_participant_joined() {
    asterisk -rx "confbridge list $CONF_NUMBER" | grep -q "PJSIP/$1"
}

is_conference_active() {
    # Проверяем наличие моста конференции
    asterisk -rx "confbridge show $CONF_NUMBER" &>/dev/null
    return $?
}

call_peers() {
    local peers_to_call=("$@")
    for peer in "${peers_to_call[@]}"; do
        if asterisk -rx "pjsip show endpoint $peer" | grep -q "Contact:"; then
            log_event "Вызов $peer (волна $((CURRENT_ATTEMPT)))"
            asterisk -rx "channel originate PJSIP/$peer application ConfBridge $CONF_NUMBER --callerid=\"$CALLER_ID\"" &
        else
            log_event "Абонент $peer не в сети!"
        fi
    done
    sleep $RETRY_DELAY
}

track_participants() {
    local current_participants=$(asterisk -rx "confbridge list $CONF_NUMBER" | grep "PJSIP/" | awk '{print $2}' | cut -d'/' -f2)
    local current_count=0
    local new_participants=()

    # Обновляем список текущих участников
    for peer in $current_participants; do
        ((current_count++))
        if [[ -z "${CURRENT_PARTICIPANTS[$peer]}" ]]; then
            log_event "Участник $peer ПОДКЛЮЧИЛСЯ к конференции"
            PARTICIPANT_STATS[$peer]="$(date '+%Y-%m-%d %H:%M:%S')"
            new_participants+=("$peer")
        fi
        CURRENT_PARTICIPANTS[$peer]=1
    done

    # Проверяем отключившихся участников
    for peer in "${!CURRENT_PARTICIPANTS[@]}"; do
        if ! grep -q "PJSIP/$peer" <<< "$current_participants"; then
            log_event "Участник $peer ОТКЛЮЧИЛСЯ от конференции"
            PARTICIPANT_STATS[$peer]+=" - $(date '+%Y-%m-%d %H:%M:%S')"
            unset CURRENT_PARTICIPANTS["$peer"]
        fi
    done

    # Обновляем время последней активности
    if [ $current_count -gt 0 ] || [ ${#new_participants[@]} -gt 0 ]; then
        LAST_ACTIVITY_TIME=$(date +%s)
    fi

    return $current_count
}

generate_report() {
    local conf_end_time=$(date +%s)
    local duration=$((conf_end_time - CONF_START_TIME))

    echo "===============================================" >> "$LOG_FILE"
    echo " ИТОГОВАЯ СВОДКА КОНФЕРЕНЦИИ $CONF_NUMBER" >> "$LOG_FILE"
    echo " Дата: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo " Длительность: $(($duration/60)) мин. $(($duration%60)) сек." >> "$LOG_FILE"
    echo "===============================================" >> "$LOG_FILE"
    echo " СТАТИСТИКА УЧАСТНИКОВ:" >> "$LOG_FILE"

    for peer in "${PEERS[@]}"; do
        if [[ -n "${PARTICIPANT_STATS[$peer]}" ]]; then
            echo " $peer: ${PARTICIPANT_STATS[$peer]}" >> "$LOG_FILE"
        else
            echo " $peer: НЕ ПОДКЛЮЧАЛСЯ" >> "$LOG_FILE"
        fi
    done

    echo "===============================================" >> "$LOG_FILE"
    echo " МАКСИМАЛЬНО УЧАСТНИКОВ: ${#PARTICIPANT_STATS[@]}" >> "$LOG_FILE"
    echo "===============================================" >> "$LOG_FILE"
}

cleanup() {
    generate_report
    rm -f "$LOCK_FILE"
    exit 0
}

# Основной скрипт #########################################################

trap cleanup EXIT TERM INT

if [ -f "$LOCK_FILE" ]; then
    log_event "ОШИБКА: Конференция $CONF_NUMBER уже запущена!"
    exit 1
fi

touch "$LOCK_FILE"
log_event "==============================================="
log_event "СТАРТ КОНФЕРЕНЦИИ $CONF_NUMBER"
log_event "Участники: ${PEERS[*]}"
log_event "==============================================="

# Создаем конференцию
asterisk -rx "confbridge create $CONF_NUMBER default_bridge default_user"

# Первая волна вызовов
CURRENT_ATTEMPT=1
call_peers "${PEERS[@]}"

# Последующие волны
while [ $CURRENT_ATTEMPT -lt $MAX_ATTEMPTS ]; do
    NEED_TO_CALL=()
    for peer in "${PEERS[@]}"; do
        if ! is_participant_joined "$peer"; then
            NEED_TO_CALL+=("$peer")
        fi
    done

    [ ${#NEED_TO_CALL[@]} -eq 0 ] && break
    CURRENT_ATTEMPT=$((CURRENT_ATTEMPT+1))
    call_peers "${NEED_TO_CALL[@]}"
done

# Основной цикл мониторинга
while true; do
    # Проверяем активность конференции
    if ! is_conference_active; then
        log_event "Конференция завершена (мост уничтожен)"
        break
    fi

    # Отслеживаем участников
    participants_count=0
    if track_participants; then
        participants_count=$?
    fi

    # Проверяем условие завершения
    current_time=$(date +%s)
    if [ $participants_count -eq 0 ] && \
       [ $(($current_time - $LAST_ACTIVITY_TIME)) -ge $GRACE_PERIOD ]; then
        log_event "Конференция завершена (нет участников в течение $GRACE_PERIOD секунд)"
        break
    fi

    sleep $MONITOR_INTERVAL
done

# Завершаем скрипт (автоматически вызовется cleanup через trap)
