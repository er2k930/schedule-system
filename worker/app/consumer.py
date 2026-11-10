import json
import logging
import os
import time

import pika
import requests

from app.mailer import send_email

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("schedule-worker")

QUEUE_NAME = "schedule.notifications"


def process_event(event: dict) -> None:
    event_type = event.get("eventType")
    schedule_id = event.get("scheduleId")

    allowed_events = {
        "SCHEDULE_UPDATED",
        "SCHEDULE_PUBLISHED",
        "SCHEDULE_CANCELLED",
    }

    if event_type not in allowed_events or not schedule_id:
        raise ValueError("Некорректное событие расписания")

    api_url = os.getenv(
        "API_INTERNAL_URL",
        "http://api:8000",
    )
    token = os.environ["WORKER_TOKEN"]

    # Получаем данные занятия и список получателей
    # Для отмены API вернет занятие со статусом CANCELLED
    response = requests.get(
        f"{api_url}/internal/schedule/{schedule_id}/notification",
        params={"event_type": event_type},
        headers={"X-Worker-Token": token},
        timeout=10,
    )

    if response.status_code == 409:
        logger.info(
            "Устаревшее событие пропущено: eventId=%s",
            event.get("eventId"),
        )
        return

    response.raise_for_status()

    schedule = response.json()
    recipients = schedule.get("recipients", [])

    if not recipients:
        logger.warning(
            "Нет получателей уведомления: scheduleId=%s",
            schedule_id,
        )
        return

    # Отправляем письма студентам и преподавателю
    # send_email сам выбирает тему и текст по event_type
    for recipient in recipients:
        send_email(
            recipient=recipient["email"],
            recipient_name=recipient["name"],
            schedule=schedule,
            event_type=event_type,
        )

    logger.info(
        "Уведомление обработано: eventId=%s, eventType=%s, recipients=%s",
        event.get("eventId"),
        event_type,
        len(recipients),
    )


def main() -> None:
    username = os.environ["RABBITMQ_WORKER_USER"]
    password = os.environ["RABBITMQ_WORKER_PASSWORD"]
    host = os.getenv("RABBITMQ_HOST", "rabbitmq")

    credentials = pika.PlainCredentials(username, password)
    parameters = pika.ConnectionParameters(
        host=host,
        port=5672,
        credentials=credentials,
        heartbeat=30,
        connection_attempts=10,
        retry_delay=5,
    )

    while True:
        try:
            connection = pika.BlockingConnection(parameters)
            channel = connection.channel()

            channel.queue_declare(
                queue=QUEUE_NAME,
                durable=True,
            )
            channel.basic_qos(prefetch_count=1)

            def callback(ch, method, properties, body):
                try:
                    event = json.loads(body.decode("utf-8"))
                    process_event(event)
                    ch.basic_ack(delivery_tag=method.delivery_tag)
                except Exception:
                    logger.exception("Не удалось обработать событие")
                    # Сообщение останется в очереди и будет обработано повторно
                    ch.basic_nack(
                        delivery_tag=method.delivery_tag,
                        requeue=True,
                    )

            channel.basic_consume(
                queue=QUEUE_NAME,
                on_message_callback=callback,
                auto_ack=False,
            )

            logger.info("Worker ожидает события...")
            channel.start_consuming()

        except Exception:
            logger.exception("Ошибка подключения Worker")
            time.sleep(5)


if __name__ == "__main__":
    main()
