-- Тестовые фоновые задачи для проверки OP-09.
-- Запускается повторно безопасно: фиксированные UUID обновляются через UPSERT.
INSERT INTO ai_jobs (
    id, owner_user_id, job_type, status, request_text,
    parsed_params, result, error_code, created_at, started_at,
    finished_at, expires_at
)
VALUES
(
    '00000000-0000-4000-8000-000000000901',
    '00000000-0000-4000-8000-000000000002',
    'AI_SCHEDULE_QUERY', 'COMPLETED',
    'Секретный текст запроса студента А',
    '{"from":"2026-11-12","to":"2026-11-12"}'::jsonb,
    '{"items":[{"id":"00000000-0000-4000-8000-000000000401"}]}'::jsonb,
    NULL, now() - interval '2 minutes', now() - interval '90 seconds',
    now() - interval '1 minute', now() + interval '7 days'
),
(
    '00000000-0000-4000-8000-000000000902',
    '00000000-0000-4000-8000-000000000003',
    'AI_SCHEDULE_QUERY', 'FAILED',
    'Секретный текст запроса студента Б',
    NULL, NULL, 'UPSTREAM_UNAVAILABLE',
    now() - interval '3 minutes', now() - interval '2 minutes',
    now() - interval '90 seconds', now() + interval '7 days'
)
ON CONFLICT (id) DO UPDATE SET
    owner_user_id = EXCLUDED.owner_user_id,
    job_type = EXCLUDED.job_type,
    status = EXCLUDED.status,
    request_text = EXCLUDED.request_text,
    parsed_params = EXCLUDED.parsed_params,
    result = EXCLUDED.result,
    error_code = EXCLUDED.error_code,
    created_at = EXCLUDED.created_at,
    started_at = EXCLUDED.started_at,
    finished_at = EXCLUDED.finished_at,
    expires_at = EXCLUDED.expires_at;
