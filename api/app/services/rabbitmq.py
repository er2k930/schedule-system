import json
import logging
import os
from uuid import uuid4

import pika

logger = logging.getLogger(__name__)

QUEUE_NAME = "schedule.notifications"


def publish_schedule_event(
    event_type: str,
    schedule_id: str,
) -> None:
    """Публикует событие об изменении опубликованного расписания."""

    username = os.environ["RABBITMQ_API_USER"]
    password = os.environ["RABBITMQ_API_PASSWORD"]
    host = os.getenv("RABBITMQ_HOST", "rabbitmq")

    credentials = pika.PlainCredentials(username, password)
    parameters = pika.ConnectionParameters(
        host=host,
        port=5672,
        credentials=credentials,
        connection_attempts=3,
        retry_delay=2,
        socket_timeout=5,
        heartbeat=30,
    )

    event = {
        "eventId": str(uuid4()),
        "eventType": event_type,
        "scheduleId": str(schedule_id),
    }

    connection = pika.BlockingConnection(parameters)

    try:
        channel = connection.channel()
        channel.queue_declare(
            queue=QUEUE_NAME,
            durable=True,
        )
        channel.confirm_delivery()

        channel.basic_publish(
            exchange="",
            routing_key=QUEUE_NAME,
            body=json.dumps(event).encode("utf-8"),
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=2,
            ),
            mandatory=True,
        )
        logger.info(
            "Schedule event published: type=%s id=%s",
            event_type,
            schedule_id,
        )
    finally:
        connection.close()