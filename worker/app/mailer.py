import os
import smtplib
from email.message import EmailMessage


def send_email(
    recipient: str,
    recipient_name: str,
    schedule: dict,
    event_type: str,
) -> None:
    message = EmailMessage()

    if event_type == "SCHEDULE_CANCELLED":
        message["Subject"] = "Отмена занятия в расписании"
        action_text = "Занятие отменено."
    else:
        message["Subject"] = "Изменение расписания занятий"
        action_text = "В расписании опубликовано изменение."

    message["From"] = os.getenv(
        "SMTP_FROM",
        "schedule@example.local",
    )
    message["To"] = recipient

    message.set_content(
        f"""Здравствуйте, {recipient_name}!

{action_text}

Группа: {schedule['group']}
Дисциплина: {schedule['subject']}
Дата и время: {schedule['startsAt']} — {schedule['endsAt']}
Аудитория: {schedule['building']}, {schedule['room']}
Преподаватель: {schedule['teacher'] or 'не назначен'}

Пожалуйста, проверьте актуальное расписание.
"""
    )

    host = os.getenv("SMTP_HOST", "mailpit")
    port = int(os.getenv("SMTP_PORT", "1025"))

    with smtplib.SMTP(host, port, timeout=10) as smtp:
        smtp.send_message(message)
