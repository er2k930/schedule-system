#!/usr/bin/env bash
# Комплексные проверки API OP-01..OP-09 и целей безопасности

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BASE_URL="${BASE_URL:-http://localhost:8000}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for tool in curl python3 docker; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ОШИБКА: не найдена команда $tool" >&2
        exit 1
    }
done

docker compose version >/dev/null 2>&1 || {
    echo "ОШИБКА: Docker Compose v2 не найден" >&2
    exit 1
}

cd "$PROJECT_DIR"

HTTP_REQUEST_COUNT=0
TEST_REQUEST_COUNT=0
LOGIN_REQUEST_COUNT=0
RATE_LIMIT_REQUEST_COUNT=0
PASS_COUNT=0
REQUEST_NO=0

CURRENT_OP="SYSTEM"
SECURITY_GOAL="Проверка доступности API и PostgreSQL."

count_request() {
    HTTP_REQUEST_COUNT=$((HTTP_REQUEST_COUNT + 1))
    REQUEST_NO=$((REQUEST_NO + 1))
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  Результат: PASS"
    echo
}

fail() {
    echo "  Результат: FAIL — $1" >&2
    exit 1
}

# Выполняет HTTP-запрос, проверяет код и выводит краткий результат.
request() {
    local label="$1"
    local expected="$2"
    local actual
    local summary

    shift 2

    count_request
    TEST_REQUEST_COUNT=$((TEST_REQUEST_COUNT + 1))

    local body="$TMP_DIR/body-$REQUEST_NO.json"
    local headers="$TMP_DIR/headers-$REQUEST_NO.txt"

    printf '[REQ %03d][%s] %s\n' "$REQUEST_NO" "$CURRENT_OP" "$label"
    printf '  Цель безопасности: %s\n' "$SECURITY_GOAL"
    printf '  Ожидалось: HTTP %s\n' "$expected"

    if ! actual="$(curl --silent --show-error --max-time 20 \
        -D "$headers" \
        -o "$body" \
        -w '%{http_code}' \
        "$@")"; then

        echo '  Получено: ошибка curl' >&2
        cat "$body" 2>/dev/null >&2 || true
        fail "$label"
    fi

    if [[ "$actual" != "$expected" ]]; then
        printf '  Получено: HTTP %s\n' "$actual" >&2
        cat "$body" >&2
        fail "$label"
    fi

    summary="$(python3 - "$body" <<'PY'
import json
import sys

raw = open(
    sys.argv[1],
    encoding="utf-8",
    errors="replace"
).read().strip()

if not raw:
    print("пустое тело")
else:
    try:
        obj = json.loads(raw)

        if isinstance(obj, dict):
            fields = ", ".join(sorted(obj))

            extra = ""
            if isinstance(obj.get("status"), str):
                extra += f"; status={obj['status']}"

            if isinstance(obj.get("detail"), str):
                detail = obj["detail"].replace("\n", " ")
                if len(detail) > 80:
                    detail = detail[:80] + "..."
                extra += "; detail=" + detail

            print(f"JSON-поля: {fields}{extra}")

        elif isinstance(obj, list):
            print(f"JSON-массив: {len(obj)} элементов")

        else:
            print(f"JSON {type(obj).__name__}")

    except Exception:
        print("текстовый ответ")
PY
)"

    printf '  Получено: HTTP %s; %s\n' "$actual" "$summary"

    pass
    LAST_BODY="$body"
}

# Проверяет структуру JSON и отсутствие закрытых полей.
assert_json() {
    local body="$1"
    local check="$2"
    local result
    local description

    case "$check" in
        job-no-request-text)
            description='только публичные поля задачи; request_text и parsed_params отсутствуют'
            ;;
        draft-response)
            description='поля черновика; status=draft; служебные поля отсутствуют'
            ;;
        response-shape-schedule-entry)
            description='точный набор полей ScheduleEntry'
            ;;
        publish-response)
            description='id, status, publishedAt; status=published'
            ;;
        response-shape-patch)
            description='точный набор полей PATCH-ответа'
            ;;
        group-a-only)
            description='непустой список только GROUP_A'
            ;;
        group-b-only)
            description='непустой список только GROUP_B'
            ;;
        login-body)
            description='тело ответа {status: ok}'
            ;;
        *)
            fail "неизвестная JSON-проверка: $check"
            ;;
    esac

    printf '[CHECK][%s] Проверка структуры JSON\n' "$CURRENT_OP"
    printf '  Цель безопасности: %s\n' "$SECURITY_GOAL"
    printf '  Ожидалось: %s\n' "$description"

    if ! result="$(python3 - "$body" "$check" <<'PY'
import json
import sys

obj = json.load(open(sys.argv[1], encoding="utf-8"))
check = sys.argv[2]

if check == "login-body":
    assert obj == {"status": "ok"}, obj
    print("status=ok")

elif check == "job-no-request-text":
    expected = {
        "jobId", "status", "result", "errorCode",
        "createdAt", "startedAt", "finishedAt"
    }
    assert set(obj) == expected, (set(obj), expected)

    forbidden = {
        "request_text", "requestText",
        "parsed_params", "parsedParams",
        "owner_user_id", "ownerUserId"
    }
    assert not forbidden.intersection(obj), forbidden.intersection(obj)

    print("публичные поля задачи; внутренних полей нет")

elif check == "draft-response":
    expected = {
        "id", "status", "createdAt", "startsAt", "endsAt"
    }
    assert set(obj) == expected and obj.get("status") == "draft", obj

    forbidden = {
        "createdBy", "createdByUserId",
        "ownerId", "role", "passwordHash"
    }
    assert not forbidden.intersection(obj), forbidden.intersection(obj)

    print("status=draft; служебных полей нет")

elif check == "response-shape-schedule-entry":
    expected = {
        "Id", "subjectId", "subjectName",
        "groupId", "groupName",
        "teacherId", "teacherName",
        "roomId", "roomName",
        "startsAt", "endsAt", "status"
    }
    assert set(obj) == expected, (set(obj), expected)

    print("поля ScheduleEntry совпадают с контрактом")

elif check == "publish-response":
    expected = {"id", "status", "publishedAt"}
    assert set(obj) == expected and obj.get("status") == "published", obj

    print("status=published; получены id и publishedAt")

elif check == "response-shape-patch":
    expected = {
        "id", "subjectId", "groupId", "teachedId",
        "roomId", "startsAt", "endsAt",
        "status", "updatedAt"
    }
    assert set(obj) == expected, (set(obj), expected)

    print("поля PATCH совпадают с контрактом")

elif check == "group-a-only":
    assert obj["items"], "Список GROUP_A пуст"
    assert all(
        x["groupName"] == "GROUP_A"
        for x in obj["items"]
    ), obj
    assert all(
        x["id"] != "00000000-0000-4000-8000-000000000402"
        for x in obj["items"]
    ), obj

    print(f"записей: {len(obj['items'])}; все GROUP_A")

elif check == "group-b-only":
    assert obj["items"], "Список GROUP_B пуст"
    assert all(
        x["groupName"] == "GROUP_B"
        for x in obj["items"]
    ), obj
    assert all(
        x["id"] != "00000000-0000-4000-8000-000000000401"
        for x in obj["items"]
    ), obj

    print(f"записей: {len(obj['items'])}; все GROUP_B")
PY
)"; then
        fail "JSON не соответствует контракту: $result"
    fi

    printf '  Получено: %s\n' "$result"
    pass
}

json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

obj = json.load(open(sys.argv[1], encoding="utf-8"))

for part in sys.argv[2].split("."):
    obj = obj[int(part)] if isinstance(obj, list) else obj[part]

print(
    obj if not isinstance(obj, (dict, list))
    else json.dumps(obj)
)
PY
}

# Проверяет полное совпадение тел двух ответов.
expect_same_body() {
    local first="$1"
    local second="$2"
    local label="$3"

    printf '[CHECK][%s] %s\n' "$CURRENT_OP" "$label"
    printf '  Цель безопасности: %s\n' "$SECURITY_GOAL"
    echo '  Ожидалось: тела ответов полностью совпадают'

    cmp -s "$first" "$second" || {
        echo '  Получено: тела ответов различаются' >&2
        echo 'Первый ответ:' >&2
        cat "$first" >&2
        echo 'Второй ответ:' >&2
        cat "$second" >&2
        fail "$label"
    }

    echo '  Получено: тела ответов полностью совпадают'
    pass
}

new_uuid() {
    python3 -c 'import uuid; print(uuid.uuid4())'
}

# Выполняет вход, сохраняет cookies и записывает CSRF-токен
# в переменную, имя которой передано пятым аргументом.
login() {
    local name="$1"
    local login_name="$2"
    local password="$3"
    local jar="$4"
    local result_variable="$5"

    local payload
    local body
    local headers
    local code
    local csrf
    local session

    payload="$(printf '%s' "$password" |
        LOGIN_NAME="$login_name" python3 -c '
import json, os, sys
print(json.dumps({
    "login": os.environ["LOGIN_NAME"],
    "password": sys.stdin.read()
}))
')"

    count_request
    LOGIN_REQUEST_COUNT=$((LOGIN_REQUEST_COUNT + 1))

    body="$TMP_DIR/login-$name.json"
    headers="$TMP_DIR/login-$name.headers"

    printf '[REQ %03d][OP-01] Вход пользователя %s\n' "$REQUEST_NO" "$name"

    if [[ "$CURRENT_OP" == "OP-01" ]]; then
        printf '  Цель безопасности: %s\n' "$SECURITY_GOAL"
    else
        echo '  Цель: получить новую сессию после проверки отзыва предыдущей; старый sessionId остаётся недействительным.'
    fi

    echo '  Ожидалось: HTTP 200; sessionId с HttpOnly; csrfToken без HttpOnly'

    if ! code="$(printf '%s' "$payload" |
        curl --silent --show-error --max-time 20 \
            -D "$headers" \
            -o "$body" \
            -w '%{http_code}' \
            -c "$jar" \
            -b "$jar" \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            "$BASE_URL/api/auth/login")"; then

        fail "ошибка curl при входе $name"
    fi

    [[ "$code" == "200" ]] || {
        printf '  Получено: HTTP %s\n' "$code" >&2
        cat "$body" >&2
        fail "вход $name"
    }

    csrf="$(awk '$6 == "csrfToken" {v=$7} END {print v}' "$jar")"
    session="$(awk '$6 == "sessionId" {v=$7} END {print v}' "$jar")"

    [[ -n "$csrf" && -n "$session" ]] || {
        echo '  Получено: sessionId/csrfToken отсутствуют' >&2
        echo '  Для HTTP требуется SESSION_COOKIE_SECURE=false' >&2
        fail "cookies $name"
    }

    grep -qi 'sessionId=.*HttpOnly' "$headers" || {
        echo '  Получено: sessionId без HttpOnly' >&2
        cat "$headers" >&2
        fail "cookie sessionId $name"
    }

    if grep -i 'csrfToken=' "$headers" | grep -qi 'HttpOnly'; then
        echo '  Получено: csrfToken имеет HttpOnly' >&2
        fail "cookie csrfToken $name"
    fi

    printf -v "$result_variable" '%s' "$csrf"

    echo '  Получено: HTTP 200; sessionId HttpOnly; csrfToken доступен клиенту'
    pass
}

# ===========================================================================
# Подготовка учётных записей
# ===========================================================================

read -r -p 'Логин администратора: ' ADMIN_LOGIN
ADMIN_LOGIN="${ADMIN_LOGIN:-admin}"

read -r -s -p 'Пароль администратора: ' ADMIN_PASSWORD
printf '\n'

read -r -p 'Логин пользователя A: ' USER_A_LOGIN
USER_A_LOGIN="${USER_A_LOGIN:-student_a}"

read -r -s -p 'Пароль пользователя A: ' USER_A_PASSWORD
printf '\n'

read -r -p 'Логин пользователя B: ' USER_B_LOGIN
USER_B_LOGIN="${USER_B_LOGIN:-student_b}"

read -r -s -p 'Пароль пользователя B: ' USER_B_PASSWORD
printf '\n'

ADMIN_JAR="$TMP_DIR/admin.cookies"
USER_A_JAR="$TMP_DIR/user-a.cookies"
USER_B_JAR="$TMP_DIR/user-b.cookies"

: > "$ADMIN_JAR"
: > "$USER_A_JAR"
: > "$USER_B_JAR"

CURRENT_OP="SYSTEM"
SECURITY_GOAL="Доступность API и соединения с PostgreSQL."

echo
echo "ПОДГОТОВКА"
request 'Health endpoint доступен' 200 "$BASE_URL/health"

# ===========================================================================
# OP-01. POST /api/auth/login - аутентификация
# ===========================================================================

CURRENT_OP="OP-01"
SECURITY_GOAL="Не раскрывать существование логина по тексту ошибки; отклонять лишние клиентские поля; выдавать защищённую sessionId-cookie и отдельный CSRF-токен."

echo
echo "OP-01. Аутентификация"

# Неизвестный логин и неверный пароль должны давать одинаковую ошибку.

request 'Неизвестный логин' 401 \
    -H 'Content-Type: application/json' \
    --data '{"login":"__unknown_user_for_security_test__","password":"WrongPassword-123!"}' \
    "$BASE_URL/api/auth/login"

INVALID_LOGIN_BODY="$LAST_BODY"

request 'Неверный пароль существующего логина' 401 \
    -H 'Content-Type: application/json' \
    --data "$(python3 -c '
import json,sys
print(json.dumps({
    "login": sys.argv[1],
    "password": "DefinitelyWrongPassword-123!"
}))
' "$ADMIN_LOGIN")" \
    "$BASE_URL/api/auth/login"

expect_same_body "$INVALID_LOGIN_BODY" "$LAST_BODY" \
    'Одинаковая ошибка для неизвестного логина и неверного пароля'

# Клиент не должен назначать себе роль через тело запроса.

request 'Лишнее поле role в теле входа запрещено' 400 \
    -H 'Content-Type: application/json' \
    --data '{"login":"admin","password":"not-used","role":"ADMIN"}' \
    "$BASE_URL/api/auth/login"

# Вход трёх пользователей и получение их CSRF-токенов.

login admin "$ADMIN_LOGIN" "$ADMIN_PASSWORD" "$ADMIN_JAR" ADMIN_CSRF
assert_json "$TMP_DIR/login-admin.json" login-body

login user_a "$USER_A_LOGIN" "$USER_A_PASSWORD" "$USER_A_JAR" USER_A_CSRF
login user_b "$USER_B_LOGIN" "$USER_B_PASSWORD" "$USER_B_JAR" USER_B_CSRF

# ===========================================================================
# OP-02. POST /api/auth/logout — CSRF и отзыв сессии
# ===========================================================================

CURRENT_OP="OP-02"
SECURITY_GOAL="Защитить logout от CSRF; отозвать серверную сессию; запретить повторное использование старого sessionId."

echo
echo "OP-02. CSRF и отзыв сессии"

# Logout без CSRF должен быть отклонён.

request 'Logout без CSRF-токена' 403 \
    -b "$USER_B_JAR" \
    -X POST "$BASE_URL/api/auth/logout"

request 'Logout с несовпадающим CSRF-токеном' 403 \
    -b "$USER_B_JAR" \
    -H 'X-CSRF-Token: wrong-token' \
    -X POST "$BASE_URL/api/auth/logout"

# Успешный logout должен отозвать серверную сессию.

request 'Успешный logout пользователя B' 200 \
    -b "$USER_B_JAR" \
    -H "X-CSRF-Token: $USER_B_CSRF" \
    -X POST "$BASE_URL/api/auth/logout"

request 'Отозванная сессия B больше не авторизует запрос' 401 \
    -b "$USER_B_JAR" \
    "$BASE_URL/api/schedule/00000000-0000-4000-8000-000000000402"

# Повторный вход нужен, чтобы B мог участвовать в OP-03—OP-09.

login user_b "$USER_B_LOGIN" "$USER_B_PASSWORD" "$USER_B_JAR" USER_B_CSRF

request 'Успешный logout пользователя A' 200 \
    -b "$USER_A_JAR" \
    -H "X-CSRF-Token: $USER_A_CSRF" \
    -X POST "$BASE_URL/api/auth/logout"

request 'Отозванная сессия A больше не авторизует запрос' 401 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/schedule/00000000-0000-4000-8000-000000000401"

login user_a "$USER_A_LOGIN" "$USER_A_PASSWORD" "$USER_A_JAR" USER_A_CSRF

request 'Успешный logout администратора' 200 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -X POST "$BASE_URL/api/auth/logout"

request 'Отозванная сессия ADMIN больше не авторизует запрос' 401 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule/00000000-0000-4000-8000-000000000401"

login admin "$ADMIN_LOGIN" "$ADMIN_PASSWORD" "$ADMIN_JAR" ADMIN_CSRF

unset ADMIN_PASSWORD USER_A_PASSWORD USER_B_PASSWORD

# ===========================================================================
# OP-03. GET /api/schedule/{id} - получение занятия
# ===========================================================================

CURRENT_OP="OP-03"
SECURITY_GOAL="Обеспечить объектный контроль доступа: пользователь видит только опубликованные занятия своей группы; чужой и отсутствующий объект неразличимы. Защита от IDOR и раскрытия существования данных."

echo
echo "OP-03. Получение занятия по ID"

SCHEDULE_A="00000000-0000-4000-8000-000000000401"
UNKNOWN_SCHEDULE="00000000-0000-4000-8000-000000000499"

request 'Без sessionId доступ к занятию запрещён' 401 \
    "$BASE_URL/api/schedule/$SCHEDULE_A"

request 'Поддельный sessionId не авторизует запрос' 401 \
    -H 'Cookie: sessionId=forged-session-value' \
    "$BASE_URL/api/schedule/$SCHEDULE_A"

request 'ADMIN читает опубликованное занятие группы A' 200 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule/$SCHEDULE_A"

assert_json "$LAST_BODY" response-shape-schedule-entry

request 'USER A читает занятие своей группы' 200 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/schedule/$SCHEDULE_A"

assert_json "$LAST_BODY" response-shape-schedule-entry

request 'USER B не читает чужое занятие (IDOR)' 404 \
    -b "$USER_B_JAR" \
    "$BASE_URL/api/schedule/$SCHEDULE_A"

FOREIGN_SCHEDULE_BODY="$LAST_BODY"

request 'Неизвестное занятие для USER B тоже возвращает 404' 404 \
    -b "$USER_B_JAR" \
    "$BASE_URL/api/schedule/$UNKNOWN_SCHEDULE"

expect_same_body "$FOREIGN_SCHEDULE_BODY" "$LAST_BODY" \
    'Чужое и несуществующее занятие неразличимы'

request 'Некорректный UUID в пути возвращает 400' 400 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule/not-a-uuid"

# ===========================================================================
# OP-04. GET /api/schedule - получение списка занятий
# ===========================================================================

CURRENT_OP="OP-04"
SECURITY_GOAL="Ограничить выдачу расписания правами пользователя; запретить USER административный groupId-фильтр; ограничить размер и период выборки, чтобы предотвратить чрезмерную выгрузку данных."

echo
echo "OP-04. Получение списка занятий"

DATE_FROM="2026-11-12"
DATE_TO="2026-11-12"
GROUP_A="00000000-0000-4000-8000-000000000101"
GROUP_B="00000000-0000-4000-8000-000000000102"

request 'Получение списка расписания без сессии запрещено' 401 \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO"

# Пагинация: разные страницы должны содержать разные записи.

request 'ADMIN получает первую страницу' 200 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&page=1&size=1"

ADMIN_PAGE1="$LAST_BODY"

request 'ADMIN получает вторую страницу' 200 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&page=2&size=1"

ADMIN_PAGE2="$LAST_BODY"

echo '[CHECK][OP-04] Проверка разделения страниц пагинации'
echo '  Цель безопасности: ограничивать объём выдачи и не возвращать одну запись на соседних страницах.'
echo '  Ожидалось: size=1; total не менее 2; ID первой и второй страницы различаются.'

if ! PAGINATION_RESULT="$(python3 - "$ADMIN_PAGE1" "$ADMIN_PAGE2" <<'PY'
import json
import sys

a, b = [
    json.load(open(path, encoding="utf-8"))
    for path in sys.argv[1:]
]

assert a["size"] == b["size"] == 1
assert a["total"] >= 2 and a["items"] and b["items"]
assert a["items"][0]["id"] != b["items"][0]["id"]

print(
    f"total={a['total']}; "
    f"page1_id={a['items'][0]['id']}; "
    f"page2_id={b['items'][0]['id']}"
)
PY
)"; then
    fail "пагинация не разделяет записи между страницами"
fi

printf '  Получено: %s\n' "$PAGINATION_RESULT"
pass

request 'USER A видит расписание только своей группы' 200 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&page=1&size=20"

assert_json "$LAST_BODY" group-a-only

request 'Фильтр groupId запрещён обычному USER' 403 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&groupId=$GROUP_B"

request 'ADMIN может фильтровать по группе B' 200 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&groupId=$GROUP_B"

assert_json "$LAST_BODY" group-b-only

request 'Фильтры по дисциплине, преподавателю и аудитории принимаются' 200 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&subjectId=00000000-0000-4000-8000-000000000201&teachedId=00000000-0000-4000-8000-000000000001&roomId=00000000-0000-4000-8000-000000000301"

request 'Начало периода позже конца отклонено' 400 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=2026-11-13&to=2026-11-12"

request 'Период больше 31 дня запрещён' 400 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=2026-11-01&to=2026-12-05"

request 'Размер страницы больше 100 запрещён' 400 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&size=101"

request 'page=0 запрещён' 400 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=$DATE_FROM&to=$DATE_TO&page=0"

request 'Некорректная дата возвращает 400' 400 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule?from=not-a-date&to=$DATE_TO"

# ===========================================================================
# OP-05. POST /api/schedule - создание занятия
# ===========================================================================

CURRENT_OP="OP-05"
SECURITY_GOAL="Разрешить создание только ADMIN и только с CSRF; запретить mass assignment серверных полей; сохранить целостность ссылок и расписания; обеспечить идемпотентность POST."

echo
echo "OP-05. Создание занятия"

request 'Создание занятия без сессии запрещено' 401 \
    -X POST \
    -H 'Content-Type: application/json' \
    --data '{"subjectId":"00000000-0000-4000-8000-000000000201","groupId":"00000000-0000-4000-8000-000000000101","teachedId":"00000000-0000-4000-8000-000000000001","roomId":"00000000-0000-4000-8000-000000000301","startsAt":"2027-01-10T09:00:00+03:00","endsAt":"2027-01-10T10:00:00+03:00"}' \
    "$BASE_URL/api/schedule"

# Генерируем новый временной интервал, чтобы не пересекаться с seed-записями.

BASE_PAYLOAD="$(python3 - <<'PY'
import json
import secrets
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone(timedelta(hours=3)))

start = (now + timedelta(days=30 + secrets.randbelow(300))).replace(
    hour=9,
    minute=secrets.randbelow(60),
    second=0,
    microsecond=0
)

end = start + timedelta(hours=1)

print(json.dumps({
    "subjectId": "00000000-0000-4000-8000-000000000201",
    "groupId": "00000000-0000-4000-8000-000000000101",
    "teachedId": "00000000-0000-4000-8000-000000000001",
    "roomId": "00000000-0000-4000-8000-000000000301",
    "startsAt": start.isoformat(),
    "endsAt": end.isoformat()
}))
PY
)"

CREATE_KEY="$(new_uuid)"

request 'USER не может создавать занятия' 403 \
    -b "$USER_A_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $USER_A_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

request 'Отсутствует CSRF-заголовок' 403 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

ADMIN_SESSION="$(awk '$6 == "sessionId" {v=$7} END {print v}' "$ADMIN_JAR")"

request 'CSRF-cookie отсутствует — запрос отклоняется' 403 \
    -H "Cookie: sessionId=$ADMIN_SESSION" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

request 'Поддельный CSRF в cookie и header не проходит HMAC-проверку' 403 \
    -H "Cookie: sessionId=$ADMIN_SESSION; csrfToken=forged-token" \
    -H 'X-CSRF-Token: forged-token' \
    -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

request 'Поддельный CSRF-токен отклоняется' 403 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H 'X-CSRF-Token: forged-token' \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

request 'Отсутствует Idempotency-Key' 400 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

request 'Idempotency-Key не является UUID' 400 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H 'Idempotency-Key: not-a-uuid' \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

# Попытка передать серверные поля в теле запроса.

EXTRA_PAYLOAD="$(python3 -c '
import json,sys
x=json.loads(sys.argv[1])
x.update({
    "id":"00000000-0000-4000-8000-000000000999",
    "status":"published",
    "createdByUserId":"00000000-0000-4000-8000-000000000002",
    "ownerId":"00000000-0000-4000-8000-000000000002",
    "role":"USER"
})
print(json.dumps(x))
' "$BASE_PAYLOAD")"

request 'Лишние поля status/id/owner/role запрещены (mass assignment)' 400 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$EXTRA_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

BAD_FK_PAYLOAD="$(python3 -c '
import json,sys
x=json.loads(sys.argv[1])
x["groupId"]="00000000-0000-4000-8000-000000000999"
print(json.dumps(x))
' "$BASE_PAYLOAD")"

request 'Несуществующая группа отклоняется' 422 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$BAD_FK_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

BAD_INTERVAL_PAYLOAD="$(python3 -c '
import json,sys
x=json.loads(sys.argv[1])
x["endsAt"]=x["startsAt"]
print(json.dumps(x))
' "$BASE_PAYLOAD")"

request 'endsAt не позже startsAt' 422 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$BAD_INTERVAL_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

CONFLICT_PAYLOAD='{
    "subjectId":"00000000-0000-4000-8000-000000000201",
    "groupId":"00000000-0000-4000-8000-000000000101",
    "teachedId":"00000000-0000-4000-8000-000000000001",
    "roomId":"00000000-0000-4000-8000-000000000302",
    "startsAt":"2026-11-12T10:15:00+03:00",
    "endsAt":"2026-11-12T11:15:00+03:00"
}'

request 'Пересечение с занятием группы возвращает 409' 409 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    --data "$CONFLICT_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

request 'ADMIN успешно создаёт занятие' 200 \
    -b "$ADMIN_JAR" \
    -c "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $CREATE_KEY" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

CREATE_BODY="$LAST_BODY"

assert_json "$CREATE_BODY" draft-response

CREATED_ID="$(json_field "$CREATE_BODY" id)"

request 'Повтор с тем же ключом возвращает первый ответ' 200 \
    -b "$ADMIN_JAR" \
    -c "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $CREATE_KEY" \
    --data "$BASE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

expect_same_body "$CREATE_BODY" "$LAST_BODY" \
    'Идемпотентность создания'

CHANGED_CREATE_PAYLOAD="$(python3 -c '
import json,sys
x=json.loads(sys.argv[1])
x["roomId"]="00000000-0000-4000-8000-000000000302"
print(json.dumps(x))
' "$BASE_PAYLOAD")"

request 'Повторное использование ключа с другим телом возвращает 409' 409 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $CREATE_KEY" \
    --data "$CHANGED_CREATE_PAYLOAD" \
    -X POST "$BASE_URL/api/schedule"

# В БД должны оказаться только серверно назначенные ADMIN и DRAFT.

DB_ACTUAL="$(docker compose exec -T postgres \
    psql -X -A -t -F '|' -U postgres -d schedule \
    -v ON_ERROR_STOP=1 \
    -c "SELECT u.login, se.status
        FROM schedule_entries se
        JOIN users u ON u.id = se.created_by_user_id
        WHERE se.id = '$CREATED_ID'::uuid;")"

DB_EXPECTED="$ADMIN_LOGIN|DRAFT"

echo '[CHECK][OP-05] Проверка серверных полей в PostgreSQL'
echo '  Цель безопасности: исключить подмену created_by_user_id и status через mass assignment.'
printf '  Ожидалось: %s\n' "$DB_EXPECTED"
printf '  Получено: %s\n' "${DB_ACTUAL:-пустой результат}"

[[ "$DB_ACTUAL" == "$DB_EXPECTED" ]] ||
    fail "создатель или статус в БД не совпадают с ожидаемыми"

pass

# ===========================================================================
# OP-06. PATCH /api/schedule/{id} - изменение занятия
# ===========================================================================

CURRENT_OP="OP-06"
SECURITY_GOAL="Разрешить изменение только ADMIN и только с CSRF; запретить изменение защищённых полей и публикацию в обход OP-07; не допускать конфликтов и лишних изменений при повторном PATCH."

echo
echo "OP-06. Изменение занятия"

request 'ADMIN получает созданный draft' 200 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/schedule/$CREATED_ID"

request 'USER A не видит draft до публикации' 404 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/schedule/$CREATED_ID"

request 'USER не может изменить занятие' 403 \
    -b "$USER_A_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $USER_A_CSRF" \
    --data '{"roomId":"00000000-0000-4000-8000-000000000302"}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

request 'PATCH без CSRF отклоняется' 403 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    --data '{"roomId":"00000000-0000-4000-8000-000000000302"}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

request 'Поддельный CSRF при PATCH отклоняется' 403 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H 'X-CSRF-Token: forged-token' \
    --data '{"roomId":"00000000-0000-4000-8000-000000000302"}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

request 'Изменение groupId запрещено (extra=forbid)' 400 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data '{"groupId":"00000000-0000-4000-8000-000000000102"}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

request 'Пустой PATCH запрещён' 400 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data '{}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

request 'Обязательное поле subjectId не может быть null' 422 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data '{"subjectId":null}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

request 'Изменение несуществующей записи возвращает 404' 404 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data '{"roomId":"00000000-0000-4000-8000-000000000302"}' \
    -X PATCH "$BASE_URL/api/schedule/00000000-0000-4000-8000-000000000499"

request 'Пересечение с другим занятием группы возвращает 409' 409 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data '{"startsAt":"2026-11-12T10:15:00+03:00","endsAt":"2026-11-12T11:15:00+03:00"}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

request 'Публикация через PATCH запрещена, использовать OP-07' 409 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data '{"status":"published"}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

# Изменение времени и аудитории, а также удаление преподавателя.

PATCH_PAYLOAD="$(python3 - "$CREATE_BODY" <<'PY'
import json
import sys
from datetime import datetime, timedelta

created = json.load(open(sys.argv[1], encoding="utf-8"))

start = datetime.fromisoformat(created["startsAt"]) + timedelta(days=2)
end = datetime.fromisoformat(created["endsAt"]) + timedelta(days=2)

print(json.dumps({
    "roomId": "00000000-0000-4000-8000-000000000302",
    "teachedId": None,
    "startsAt": start.isoformat(),
    "endsAt": end.isoformat()
}))
PY
)"

request 'ADMIN изменяет время/аудиторию и снимает преподавателя' 200 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data "$PATCH_PAYLOAD" \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

PATCH_BODY="$LAST_BODY"

assert_json "$PATCH_BODY" response-shape-patch

request 'Повтор того же PATCH не создаёт нового изменения' 200 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data "$PATCH_PAYLOAD" \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

expect_same_body "$PATCH_BODY" "$LAST_BODY" \
    'Повтор идентичного PATCH сохраняет updatedAt'

# ===========================================================================
# OP-07. POST /api/schedule/{id}/publish - публикация занятия
# ===========================================================================

CURRENT_OP="OP-07"
SECURITY_GOAL="Разрешить публикацию только ADMIN; защитить операцию CSRF и Idempotency-Key; исключить повторную публикацию и повторное использование ключа для другого объекта."

echo
echo "OP-07. Публикация занятия"

PUBLISH_KEY="$(new_uuid)"

request 'USER не может публиковать запись' 403 \
    -b "$USER_A_JAR" \
    -H "X-CSRF-Token: $USER_A_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    -X POST "$BASE_URL/api/schedule/$CREATED_ID/publish"

request 'Публикация без CSRF отклоняется' 403 \
    -b "$ADMIN_JAR" \
    -H "Idempotency-Key: $(new_uuid)" \
    -X POST "$BASE_URL/api/schedule/$CREATED_ID/publish"

request 'Публикация без Idempotency-Key отклоняется' 400 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -X POST "$BASE_URL/api/schedule/$CREATED_ID/publish"

request 'Некорректный Idempotency-Key отклоняется' 400 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H 'Idempotency-Key: invalid-key' \
    -X POST "$BASE_URL/api/schedule/$CREATED_ID/publish"

request 'ADMIN публикует draft' 200 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $PUBLISH_KEY" \
    -X POST "$BASE_URL/api/schedule/$CREATED_ID/publish"

assert_json "$LAST_BODY" publish-response

PUBLISH_BODY="$LAST_BODY"

request 'Повтор публикации с тем же ключом возвращает исходный ответ' 200 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $PUBLISH_KEY" \
    -X POST "$BASE_URL/api/schedule/$CREATED_ID/publish"

expect_same_body "$PUBLISH_BODY" "$LAST_BODY" \
    'Идемпотентность публикации'

request 'Повторное использование ключа для другого ID запрещено' 409 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $PUBLISH_KEY" \
    -X POST "$BASE_URL/api/schedule/$SCHEDULE_A/publish"

request 'Повторная публикация с новым ключом запрещена' 409 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    -X POST "$BASE_URL/api/schedule/$CREATED_ID/publish"

request 'Публикация неизвестной записи возвращает 404' 404 \
    -b "$ADMIN_JAR" \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    -H "Idempotency-Key: $(new_uuid)" \
    -X POST "$BASE_URL/api/schedule/$UNKNOWN_SCHEDULE/publish"

request 'USER A видит опубликованное занятие своей группы' 200 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/schedule/$CREATED_ID"

request 'USER B не видит занятие чужой группы' 404 \
    -b "$USER_B_JAR" \
    "$BASE_URL/api/schedule/$CREATED_ID"

# Зависимый сценарий OP-06: отмена возможна только после публикации.
# Поэтому проверка перехода PUBLISHED -> CANCELLED выполняется здесь.

CURRENT_OP="OP-06"
SECURITY_GOAL="Разрешить переход PUBLISHED -> CANCELLED только ADMIN с CSRF; не допустить изменения статуса без привилегий."

request 'ADMIN отменяет опубликованное занятие' 200 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $ADMIN_CSRF" \
    --data '{"status":"cancelled"}' \
    -X PATCH "$BASE_URL/api/schedule/$CREATED_ID"

CURRENT_OP="OP-07"

# ===========================================================================
# OP-08. POST /api/schedule/ai-query - AI-запрос
# ===========================================================================

CURRENT_OP="OP-08"
SECURITY_GOAL="Не допускать неавторизованный вызов защищённой операции; подтвердить предусмотренный заглушечный ответ 501 без запуска AI-интеграции."

echo
echo "OP-08. AI-запрос"

request 'AI-запрос без сессии возвращает 401' 401 \
    -X POST "$BASE_URL/api/schedule/ai-query"

request 'USER получает 501 Not Implemented' 501 \
    -b "$USER_A_JAR" \
    -H 'Content-Type: application/json' \
    --data '{"query":"занятия завтра"}' \
    -X POST "$BASE_URL/api/schedule/ai-query"

request 'ADMIN получает 501 Not Implemented' 501 \
    -b "$ADMIN_JAR" \
    -H 'Content-Type: application/json' \
    --data '{"query":"занятия завтра"}' \
    -X POST "$BASE_URL/api/schedule/ai-query"

# ===========================================================================
# OP-09. GET /api/jobs/{id} — получение фоновой задачи
# ===========================================================================

CURRENT_OP="OP-09"
SECURITY_GOAL="Ограничить чтение задач владельцем и ADMIN; скрывать чужие задачи так же, как несуществующие; не раскрывать request_text и parsed_params."

echo
echo "OP-09. Получение фоновой задачи"

JOB_A="00000000-0000-4000-8000-000000000901"
JOB_B="00000000-0000-4000-8000-000000000902"
UNKNOWN_JOB="00000000-0000-4000-8000-000000000999"

echo '[OP-09] Подготовка тестовых задач'

docker compose exec -T postgres \
    psql -U postgres -d schedule -v ON_ERROR_STOP=1 \
    < "$SCRIPT_DIR/jobs-fixtures.sql" >/dev/null

request 'Получение задачи без сессии запрещено' 401 \
    "$BASE_URL/api/jobs/$JOB_A"

request 'USER A получает собственную задачу' 200 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/jobs/$JOB_A"

assert_json "$LAST_BODY" job-no-request-text

request 'USER A не получает задачу пользователя B (IDOR)' 404 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/jobs/$JOB_B"

FOREIGN_JOB_BODY="$LAST_BODY"

request 'Несуществующая задача также возвращает 404' 404 \
    -b "$USER_A_JAR" \
    "$BASE_URL/api/jobs/$UNKNOWN_JOB"

expect_same_body "$FOREIGN_JOB_BODY" "$LAST_BODY" \
    'Чужая и несуществующая задача неразличимы'

request 'USER B не получает задачу пользователя A (IDOR)' 404 \
    -b "$USER_B_JAR" \
    "$BASE_URL/api/jobs/$JOB_A"

request 'ADMIN получает задачу другого пользователя' 200 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/jobs/$JOB_B"

assert_json "$LAST_BODY" job-no-request-text

request 'Некорректный UUID задачи возвращает 400' 400 \
    -b "$ADMIN_JAR" \
    "$BASE_URL/api/jobs/not-a-uuid"

# ===========================================================================
# Дополнительная проверка OP-04. Rate limit
# ===========================================================================
# Запускается после OP-09, чтобы HTTP 429 не блокировал остальные тесты.

CURRENT_OP="OP-04"
SECURITY_GOAL="Ограничить частоту запросов одного пользователя: не более 60 запросов за 60 секунд; при превышении возвращать HTTP 429."

echo
echo "Дополнительная проверка OP-04. Rate limit"

printf '  Цель безопасности: %s\n' "$SECURITY_GOAL"
echo '  Ожидалось: после превышения лимита сервер возвращает HTTP 429.'

RATE_LIMIT_HIT=false
RATE_CODE=""

for ((attempt = 1; attempt <= 70; attempt++)); do
    count_request
    RATE_LIMIT_REQUEST_COUNT=$((RATE_LIMIT_REQUEST_COUNT + 1))

    RATE_CODE="$(curl --silent --show-error --max-time 10 \
        -o "$TMP_DIR/rate-limit.json" \
        -w '%{http_code}' \
        -b "$ADMIN_JAR" \
        "$BASE_URL/api/schedule/$SCHEDULE_A")" ||
        fail "curl завершился с ошибкой в rate limit"

    if [[ "$RATE_CODE" == "429" ]]; then
        RATE_LIMIT_HIT=true
        break
    fi

    if [[ "$RATE_CODE" != "200" ]]; then
        printf '  Получено: HTTP %s вместо HTTP 200 или 429\n' "$RATE_CODE" >&2
        cat "$TMP_DIR/rate-limit.json" >&2
        fail "проверка rate limit"
    fi
done

[[ "$RATE_LIMIT_HIT" == "true" ]] || {
    echo '  Получено: HTTP 429 не получен за 70 попыток' >&2
    fail 'rate limit не сработал'
}

printf '  Получено: HTTP 429 на попытке %s\n' "$attempt"
pass

# ===========================================================================
# Итог
# ===========================================================================

echo
echo "ИТОГ"
echo "============================================================"

printf 'HTTP-запросов всего: %s\n' "$HTTP_REQUEST_COUNT"
printf '  Основные запросы тестов: %s\n' "$TEST_REQUEST_COUNT"
printf '  Запросы входа в систему: %s\n' "$LOGIN_REQUEST_COUNT"
printf '  Запросы проверки rate limit: %s\n' "$RATE_LIMIT_REQUEST_COUNT"
printf 'Успешных проверок (HTTP + JSON + БД + идемпотентность): %s\n' "$PASS_COUNT"
echo "Все проверки OP-01..OP-09 завершены."