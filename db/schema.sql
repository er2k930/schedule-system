CREATE TYPE user_role AS ENUM ('USER', 'ADMIN', 'TECH_ADMIN');
CREATE TYPE person_type AS ENUM ('STUDENT', 'EMPLOYEE');
CREATE TYPE schedule_status AS ENUM ('DRAFT', 'PUBLISHED', 'CANCELLED');
CREATE TYPE job_type AS ENUM ('AI_SCHEDULE_QUERY');
CREATE TYPE job_status AS ENUM ('QUEUED', 'RUNNING', 'COMPLETED', 'FAILED', 'EXPIRED');

CREATE TABLE users (
  id UUID PRIMARY KEY,
  login VARCHAR(64) NOT NULL UNIQUE,
  email VARCHAR(320) NOT NULL UNIQUE,
  full_name VARCHAR(200) NOT NULL,
  person_type person_type NOT NULL,
  role user_role NOT NULL DEFAULT 'USER',
  password_hash TEXT NOT NULL,
  password_salt BYTEA NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_password_salt_length CHECK (octet_length(password_salt) >= 16)
);

CREATE TABLE groups (
  id UUID PRIMARY KEY,
  name VARCHAR(64) NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE group_members (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, group_id)
);

CREATE INDEX idx_group_members_group_user ON group_members(group_id, user_id);

CREATE TABLE subjects (
  id UUID PRIMARY KEY,
  name VARCHAR(200) NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE rooms (
  id UUID PRIMARY KEY,
  building VARCHAR(120) NOT NULL,
  room_number VARCHAR(32) NOT NULL,
  CONSTRAINT uq_room UNIQUE (building, room_number)
);

CREATE TABLE schedule_entries (
  id UUID PRIMARY KEY,
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  subject_id UUID NOT NULL REFERENCES subjects(id) ON DELETE RESTRICT,
  teacher_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE RESTRICT,
  created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  status schedule_status NOT NULL DEFAULT 'DRAFT',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at TIMESTAMPTZ,
  CONSTRAINT chk_schedule_time CHECK (ends_at > starts_at),
  CONSTRAINT chk_published_at CHECK (
    (status = 'PUBLISHED' AND published_at IS NOT NULL)
    OR (status <> 'PUBLISHED')
  )
);

CREATE INDEX idx_schedule_group ON schedule_entries(group_id);
CREATE INDEX idx_schedule_starts_at ON schedule_entries(starts_at);
CREATE INDEX idx_schedule_group_time ON schedule_entries(group_id, starts_at);
CREATE INDEX idx_schedule_subject_time ON schedule_entries(subject_id, starts_at);
CREATE INDEX idx_schedule_teacher_time ON schedule_entries(teacher_id, starts_at);
CREATE INDEX idx_schedule_room_time ON schedule_entries(room_id, starts_at);

CREATE UNIQUE INDEX uq_active_group_start
  ON schedule_entries(group_id, starts_at)
  WHERE status <> 'CANCELLED';

CREATE UNIQUE INDEX uq_active_room_start
  ON schedule_entries(room_id, starts_at)
  WHERE room_id IS NOT NULL AND status <> 'CANCELLED';

CREATE UNIQUE INDEX uq_active_teacher_start
  ON schedule_entries(teacher_id, starts_at)
  WHERE teacher_id IS NOT NULL AND status <> 'CANCELLED';

CREATE TABLE sessions (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash BYTEA NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  CONSTRAINT chk_session_expiration CHECK (expires_at > created_at)
);

CREATE INDEX idx_sessions_user ON sessions(user_id);
CREATE INDEX idx_sessions_expiration ON sessions(expires_at);

CREATE TABLE calendar_integrations (
  id UUID PRIMARY KEY,
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider VARCHAR(32) NOT NULL,
  external_calendar_id VARCHAR(200) NOT NULL,
  credential_ref VARCHAR(200),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_sync_at TIMESTAMPTZ,
  CONSTRAINT uq_calendar_integration UNIQUE (owner_user_id, provider, external_calendar_id)
);

CREATE INDEX idx_calendar_integrations_owner ON calendar_integrations(owner_user_id);

CREATE TABLE ai_jobs (
  id UUID PRIMARY KEY,
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  job_type job_type NOT NULL,
  status job_status NOT NULL DEFAULT 'QUEUED',
  request_text TEXT NOT NULL,
  parsed_params JSONB,
  result JSONB,
  error_code VARCHAR(64),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_ai_jobs_owner ON ai_jobs(owner_user_id);
CREATE INDEX idx_ai_jobs_status ON ai_jobs(status);
CREATE INDEX idx_ai_jobs_owner_status ON ai_jobs(owner_user_id, status);

CREATE TABLE idempotency_keys (
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key UUID NOT NULL,
  endpoint VARCHAR(200) NOT NULL,
  request_hash BYTEA NOT NULL,
  response_status SMALLINT,
  response_body JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (owner_user_id, key)
);

CREATE INDEX idx_idempotency_expiration ON idempotency_keys(expires_at);

CREATE TABLE audit_events (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  actor_service VARCHAR(64),
  action VARCHAR(64) NOT NULL,
  object_type VARCHAR(64) NOT NULL,
  object_id UUID,
  result VARCHAR(16) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  details JSONB,
  CONSTRAINT chk_audit_actor CHECK (
    actor_user_id IS NOT NULL OR actor_service IS NOT NULL
  )
);

CREATE INDEX idx_audit_actor_time ON audit_events(actor_user_id, created_at);
CREATE INDEX idx_audit_object ON audit_events(object_type, object_id);