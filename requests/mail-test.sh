
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
MAILPIT_URL="${MAILPIT_URL:-http://localhost:8025}"

TMP_DIR="$(mktemp -d)"
COOKIE_JAR="$TMP_DIR/admin.cookies"
RESPONSE="$TMP_DIR/response.json"

trap 'rm -rf "$TMP_DIR"' EXIT

# Проверяем доступность сервисов.
curl -fsS "$BASE_URL/health"
echo

curl -fsS "$MAILPIT_URL/api/v1/info" >/dev/null
echo "Mailpit доступен."

# Вход администратора.
read -r -p "Логин ADMIN: " ADMIN_LOGIN
ADMIN_LOGIN="${ADMIN_LOGIN:-admin}"

read -r -s -p "Пароль ADMIN: " ADMIN_PASSWORD
printf '\n'

LOGIN_JSON="$(
  printf '%s' "$ADMIN_PASSWORD" |
  ADMIN_LOGIN="$ADMIN_LOGIN" python3 -c '
import json, os, sys
print(json.dumps({
    "login": os.environ["ADMIN_LOGIN"],
    "password": sys.stdin.read()
}))
'
)"
unset ADMIN_PASSWORD

LOGIN_CODE="$(
  printf '%s' "$LOGIN_JSON" |
  curl -sS \
    -o "$TMP_DIR/login.json" \
    -w '%{http_code}' \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    "$BASE_URL/api/auth/login"
)"
unset LOGIN_JSON

if [[ "$LOGIN_CODE" != "200" ]]; then
    echo "Ошибка входа: HTTP $LOGIN_CODE"
    cat "$TMP_DIR/login.json"
    exit 1
fi

echo "ADMIN: вход выполнен."

CSRF_TOKEN="$(
  awk '$6 == "csrfToken" {v=$7} END {print v}' "$COOKIE_JAR"
)"

if [[ -z "$CSRF_TOKEN" ]]; then
    echo "Не найден csrfToken. Проверь SESSION_COOKIE_SECURE=false."
    exit 1
fi

# Вспомогательная функция проверки HTTP-кода.
request() {
    local label="$1"
    local expected="$2"
    shift 2

    local actual
    actual="$(
      curl -sS \
        -o "$RESPONSE" \
        -w '%{http_code}' \
        "$@"
    )"

    echo
    echo "$label: HTTP $actual"

    if [[ "$actual" != "$expected" ]]; then
        echo "Ожидался HTTP $expected. Ответ:"
        cat "$RESPONSE"
        exit 1
    fi

    cat "$RESPONSE"
    echo
}

# Получаем число писем в Mailpit.
mail_count() {
    curl -fsS "$MAILPIT_URL/api/v1/messages?limit=1" |
      python3 -c '
import json, sys
print(json.load(sys.stdin)["total"])
'
}

# Ждём, пока Worker доставит ожидаемое количество писем.
wait_for_mail_count() {
    local target="$1"
    local attempts=0
    local current

    while (( attempts < 30 )); do
        current="$(mail_count)"

        if (( current >= target )); then
            echo "Mailpit: получено писем $current (ожидалось не менее $target)."
            return 0
        fi

        sleep 1
        attempts=$((attempts + 1))
    done

    echo "Письма не поступили. Последнее состояние Mailpit:"
    curl -fsS "$MAILPIT_URL/api/v1/messages?limit=20" |
      python3 -m json.tool
    return 1
}

MAIL_BEFORE="$(mail_count)"
echo "Писем до теста: $MAIL_BEFORE"

# Создаём уникальный временной интервал в будущем.
read -r STARTS_AT ENDS_AT < <(
  python3 - <<'PY'
from datetime import datetime, timedelta
from random import randint

start = datetime.now().astimezone() + timedelta(days=180 + randint(0, 500))
start = start.replace(
    hour=9,
    minute=randint(0, 59),
    second=0,
    microsecond=0,
)
end = start + timedelta(hours=1)

print(start.isoformat(), end.isoformat())
PY
)

CREATE_PAYLOAD="$(
  STARTS_AT="$STARTS_AT" ENDS_AT="$ENDS_AT" python3 - <<'PY'
import json, os

print(json.dumps({
    "subjectId": "00000000-0000-4000-8000-000000000201",
    "groupId": "00000000-0000-4000-8000-000000000101",
    "teachedId": "00000000-0000-4000-8000-000000000001",
    "roomId": "00000000-0000-4000-8000-000000000301",
    "startsAt": os.environ["STARTS_AT"],
    "endsAt": os.environ["ENDS_AT"]
}))
PY
)"

# OP-05: создаём DRAFT.
CREATE_KEY="$(python3 -c 'import uuid; print(uuid.uuid4())')"

request "OP-05: создание черновика" 200 \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $CSRF_TOKEN" \
    -H "Idempotency-Key: $CREATE_KEY" \
    --data "$CREATE_PAYLOAD" \
    "$BASE_URL/api/schedule"

SCHEDULE_ID="$(
  python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["id"])
' "$RESPONSE"
)"

echo "ID созданного занятия: $SCHEDULE_ID"

# Проверяем, что черновик не вызвал отправку писем.
sleep 2
MAIL_AFTER_DRAFT="$(mail_count)"

if [[ "$MAIL_AFTER_DRAFT" != "$MAIL_BEFORE" ]]; then
    echo "FAIL: после создания DRAFT появились новые письма."
    exit 1
fi

echo "PASS: создание DRAFT не вызвало рассылку."

# OP-07: публикуем занятие.
PUBLISH_KEY="$(python3 -c 'import uuid; print(uuid.uuid4())')"

request "OP-07: публикация занятия" 200 \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "X-CSRF-Token: $CSRF_TOKEN" \
    -H "Idempotency-Key: $PUBLISH_KEY" \
    -X POST \
    "$BASE_URL/api/schedule/$SCHEDULE_ID/publish"

wait_for_mail_count "$((MAIL_BEFORE + 1))"

# OP-06: изменяем опубликованное занятие.
request "OP-06: изменение опубликованного занятия" 200 \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $CSRF_TOKEN" \
    --data '{"roomId":"00000000-0000-4000-8000-000000000302"}' \
    -X PATCH \
    "$BASE_URL/api/schedule/$SCHEDULE_ID"

wait_for_mail_count "$((MAIL_BEFORE + 2))"

# OP-06: отменяем опубликованное занятие.
request "OP-06: отмена опубликованного занятия" 200 \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $CSRF_TOKEN" \
    --data '{"status":"cancelled"}' \
    -X PATCH \
    "$BASE_URL/api/schedule/$SCHEDULE_ID"

wait_for_mail_count "$((MAIL_BEFORE + 3))"

echo
echo "Все проверки рассылки пройдены."
echo "Занятие: $SCHEDULE_ID"
echo "Ожидаемое количество новых писем: 3"
echo "Mailpit: $MAILPIT_URL"
