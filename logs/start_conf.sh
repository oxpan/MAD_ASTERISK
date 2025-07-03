#!/bin/bash
# Настройки
CONF_NUMBER="900"          # Номер конференции
PEERS=("100" "101" "102" "103" "104" "105" "106" "107")  # Ваши абоненты
LOCK_FILE="/tmp/conf_lock1332.lock" #фай для блокировки конференции, уничтожается по завершению скрипта
LOG_FILE="/var/log/asterisk/conf.log" #логирование скрипта для дебага
CALLER_ID="conf <900>" # номер конференции (но это не работает)
MAX_RETRIS=3 #колич попыток
RETRY_DELAY=15 #задержка между попытками


# Проверяем, есть ли уже конференция
if [ -f "$LOCK_FILE" ]; then
  echo "$(date) - Конференция уже активна" >> "$LOG_FILE"
  exit 1
fi

touch "$LOCK_FILE"
echo  "$(date) - Старт конференции $CONF_NUMBER" >> "$LOG_FILE"

#эта функция для проверки учасника конференции входной параметр это номер абонента
is_participant_joined(){
  asterisk -rx "confbridge list $CONF_NUMBER" | grep -q "PJSIP/$1"
}

# 1.
#/usr/sbin/asterisk -rx "channel originate Local/$CONF_NUMBER@from-internal application ConfBridge $CONF_NUMBER"
asterisk -rx "confbridge create $CONF_NUMBER default_bridge default_user"

# 2/ вызываем всех абонентом первым прогоном
declare -A call_pids
for peer in "${PEERS[@]}"; do
  if asterisk -rx "pjsip show endpoint $peer" | grep -q "Contact:";then
    echo "$(date) - первый вызов $peer..." >> "$LOG_FILE"
    asterisk -rx "channel originate PJSIP/$peer application ConfBridge $CONF_NUMBER --callerid=\"$CALLER_ID\""&
    call_pids[$peer]=$!
  else
      echo "$(date) - абонент $peer не в сети!" >> "$LOG_FILE"
  fi
done

# 3. для ожидания прозвона первой волны
sleep $RETRY_DELAY

# 4. здесь обходим неуспевших т.е. дозвон
for peer in "${PEERS[@]}"; do
  attemp=2
#  echo "$(date) - FFFFFFuck..." >> "$LOG_FILE"
  while [ $attemp -le $MAX_RETRIS ]; do

    if asterisk -rx "pjsip show endpoint $peer" | grep -q "Contact:" && ! is_participant_joined "$peer";then
      echo "$(date) - попытка $attemp вызова $peer..." >> "$LOG_FILE"
      asterisk -rx "channel originate PJSIP/$peer application ConfBridge $CONF_NUMBER --callerid=\"$CALLER_ID\""
      sleep $RETRY_DELAY

      if is_participant_joined "$peer"; then
        echo "$(date) - $peer успешно подключился" >> "$LOG_FILE"
        break
      fi
       attemp=$((attemp+1))
    else
      #echo "$(date) - абонент $peer не в сети!" >> "$LOG_FILE"
      break
    fi
  done
    if [ $attemp -gt $MAX_RETRIS ] && is_participant_joined "$peer"; then
      echo "$(date) - не удалось дозвонится до $peer после $MAX_RETRIS попыток" >> "$LOG_FILE"
    fi
done

(sleep 300; rm -f "$LOCK_FILE") & echo "$(date) - Вызовы завершены" >> "$LOG_FILE"

#бля
