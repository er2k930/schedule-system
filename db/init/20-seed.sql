-- Демонстрационные данные
-- Все пароли хранятся в виде Argon2id-хешей

INSERT INTO users (
    id,
    login,
    email,
    full_name,
    person_type,
    role,
    password_hash,
    password_salt
)
VALUES
(
    '00000000-0000-4000-8000-000000000001',
    'admin',
    'admin@example.local',
    'Демо Администратор',
    'EMPLOYEE',
    'ADMIN',
    '60af5a25ef07938c3d2a24f82a10bb53e02bf19dd2937db06fe9a1633a52b310',
    decode('c76f7865def45ea98427cc0260a997cd', 'hex')
),
(
    '00000000-0000-4000-8000-000000000002',
    'student_a',
    'student_a@example.local',
    'Студент А',
    'STUDENT',
    'USER',
    'd4f3fcf6a864c068a01ebccbd4a2e78da8ef7be8a2bcbfc9788ecd00e64248c3',
    decode('ad983c48ca8251cb604cdf5c46d8aa71', 'hex')
),
(
    '00000000-0000-4000-8000-000000000003',
    'student_b',
    'student_b@example.local',
    'Студент Б',
    'STUDENT',
    'USER',
    '89f06ec869328c139b88b2e65787a9a0cca1d6dcb11d1d835b4f54a5ac628257',
    decode('478bbb7674da190ed01fd738d58f2405', 'hex')
)
ON CONFLICT (id) DO NOTHING;


-- Учебные группы

INSERT INTO groups (id, name)
VALUES
(
    '00000000-0000-4000-8000-000000000101',
    'GROUP_A'
),
(
    '00000000-0000-4000-8000-000000000102',
    'GROUP_B'
)
ON CONFLICT (id) DO NOTHING;


-- Членство пользователей в группах

INSERT INTO group_members (user_id, group_id)
VALUES
(
    '00000000-0000-4000-8000-000000000002',
    '00000000-0000-4000-8000-000000000101'
),
(
    '00000000-0000-4000-8000-000000000003',
    '00000000-0000-4000-8000-000000000102'
)
ON CONFLICT DO NOTHING;


-- Дисциплины

INSERT INTO subjects (id, name)
VALUES (
    '00000000-0000-4000-8000-000000000201',
    'Основы программирования'
)
ON CONFLICT (id) DO NOTHING;


-- Аудитории

INSERT INTO rooms (id, building, room_number)
VALUES
(
    '00000000-0000-4000-8000-000000000301',
    'Главный корпус',
    '301'
),
(
    '00000000-0000-4000-8000-000000000302',
    'Главный корпус',
    '302'
)
ON CONFLICT (id) DO NOTHING;


-- Занятия

INSERT INTO schedule_entries (
    id,
    group_id,
    subject_id,
    teacher_id,
    room_id,
    created_by_user_id,
    starts_at,
    ends_at,
    status,
    published_at
)
VALUES
(
    '00000000-0000-4000-8000-000000000401',
    '00000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000201',
    '00000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000301',
    '00000000-0000-4000-8000-000000000001',
    '2026-11-12 10:00:00+03',
    '2026-11-12 11:30:00+03',
    'PUBLISHED',
    now()
),
(
    '00000000-0000-4000-8000-000000000402',
    '00000000-0000-4000-8000-000000000102',
    '00000000-0000-4000-8000-000000000201',
    '00000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000302',
    '00000000-0000-4000-8000-000000000001',
    '2026-11-12 12:00:00+03',
    '2026-11-12 13:30:00+03',
    'PUBLISHED',
    now()
)
ON CONFLICT (id) DO NOTHING;