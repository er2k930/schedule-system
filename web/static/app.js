
'use strict';

const API = '/api';
const PAGE_SIZE = 20;

const state = {
  user: null,
  page: 1,
  total: 0,
  options: null,
  entries: [],
  editingId: null,
};

const $ = (id) => document.getElementById(id);

// -------------------- Вспомогательные функции --------------------

function localDateString(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
}

function dateTimeLocalString(date) {
  const shifted = new Date(
    date.getTime() - date.getTimezoneOffset() * 60000
  );

  return shifted.toISOString().slice(0, 16);
}

function toApiDateTime(value) {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    throw new Error('Проверьте дату и время занятия.');
  }

  return date.toISOString();
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (char) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  })[char]);
}

// -------------------- CSRF-защита --------------------

function csrfToken() {
  const cookie = document.cookie
    .split('; ')
    .find((part) => part.startsWith('csrfToken='));

  return cookie
    ? decodeURIComponent(cookie.slice('csrfToken='.length))
    : '';
}

function requestHeaders(extra = {}) {
  const headers = {
    Accept: 'application/json',
    ...extra,
  };

  const token = csrfToken();

  if (token) {
    headers['X-CSRF-Token'] = token;
  }

  return headers;
}

// -------------------- Работа с API --------------------

async function apiRequest(path, options = {}) {
  const response = await fetch(`${API}${path}`, {
    credentials: 'same-origin',
    cache: 'no-store',
    ...options,
    headers: requestHeaders(options.headers || {}),
  });

  let data = null;

  const contentType = response.headers.get('content-type') || '';

  if (contentType.includes('application/json')) {
    data = await response.json();
  }

  if (!response.ok) {
    if (response.status === 401 && path !== '/auth/login') {
      showLogin('Сессия завершилась. Войдите в систему ещё раз.');
    }

    const detail = data?.detail;

    const message = Array.isArray(detail)
      ? detail.map((item) => item.msg || 'Некорректные данные').join('; ')
      : (detail || `Ошибка запроса (${response.status})`);

    throw new Error(message);
  }

  return data;
}

// -------------------- Сообщения интерфейса --------------------

function showToast(message, isError = false) {
  const toast = $('toast');

  toast.textContent = message;
  toast.classList.toggle('error', isError);
  toast.classList.add('visible');

  clearTimeout(showToast.timer);

  showToast.timer = setTimeout(() => {
    toast.classList.remove('visible');
  }, 3500);
}

// -------------------- Авторизация --------------------

function showLogin(message = '') {
  state.user = null;

  $('schedule-view').hidden = true;
  $('user-area').hidden = true;
  $('login-view').hidden = false;

  $('login-error').textContent = message;
  $('login-error').hidden = !message;

  $('password').value = '';
}

function showSchedule() {
  $('login-view').hidden = true;
  $('schedule-view').hidden = false;
  $('user-area').hidden = false;

  $('user-name').textContent =
    state.user.fullName || state.user.login;

  $('user-role').textContent =
    state.user.role === 'ADMIN'
      ? 'Администратор'
      : 'Пользователь';

  $('welcome-text').textContent =
    state.user.role === 'ADMIN'
      ? 'Управляйте занятиями и следите за изменениями расписания.'
      : 'Здесь отображаются опубликованные занятия ваших учебных групп.';

  $('new-entry-button').hidden =
    state.user.role !== 'ADMIN';

  document.querySelectorAll('.admin-filter').forEach((element) => {
    element.hidden = state.user.role !== 'ADMIN';
  });
}

async function loadCurrentUser() {
  try {
    state.user = await apiRequest('/auth/me');

    showSchedule();

    if (state.user.role === 'ADMIN') {
      await loadOptions();
    }

    await loadSchedule();

  } catch (error) {
    if (
      !state.user ||
      error.message.includes('401') ||
      error.message.includes('авторизац')
    ) {
      showLogin();
      return;
    }

    showToast(error.message, true);
  }
}

// -------------------- Справочники --------------------

async function loadOptions() {
  state.options = await apiRequest('/schedule/options');

  fillSelect(
    'entry-subject',
    state.options.subjects,
    (item) => item.name,
    'Выберите дисциплину'
  );

  fillSelect(
    'entry-group',
    state.options.groups,
    (item) => item.name,
    'Выберите группу'
  );

  fillSelect(
    'filter-group',
    state.options.groups,
    (item) => item.name,
    'Все группы',
    true
  );

  fillSelect(
    'entry-room',
    state.options.rooms,
    (item) => item.name,
    'Выберите аудиторию'
  );

  fillSelect(
    'entry-teacher',
    state.options.teachers,
    (item) => item.fullName,
    'Не назначен',
    true
  );
}

function fillSelect(id, items, label, placeholder, allowEmpty = false) {
  const select = $(id);

  select.replaceChildren();

  const first = document.createElement('option');

  first.value = '';
  first.textContent = placeholder;

  if (!allowEmpty) {
    first.disabled = true;
  }

  first.selected = true;

  select.append(first);

  for (const item of items || []) {
    const option = document.createElement('option');

    option.value = item.id;
    option.textContent = label(item);

    select.append(option);
  }
}

// -------------------- Отображение расписания --------------------

function formatTime(value) {
  return new Date(value).toLocaleTimeString('ru-RU', {
    hour: '2-digit',
    minute: '2-digit',
  });
}

function formatPeriod(from, to) {
  const first = new Date(`${from}T00:00:00`);
  const last = new Date(`${to}T00:00:00`);

  const dateFormat = {
    day: 'numeric',
    month: 'long',
  };

  const firstText = first.toLocaleDateString(
    'ru-RU',
    dateFormat
  );

  const lastText = last.toLocaleDateString(
    'ru-RU',
    {
      ...dateFormat,
      year: 'numeric',
    }
  );

  return from === to
    ? lastText
    : `${firstText} — ${lastText}`;
}

function statusInfo(status) {
  const normalized = String(status || '').toLowerCase();

  const values = {
    published: ['Опубликовано', 'status-published'],
    draft: ['Черновик', 'status-draft'],
    cancelled: ['Отменено', 'status-cancelled'],
  };

  return values[normalized] ||
    ['Неизвестно', 'status-draft'];
}

async function loadSchedule() {
  const from = $('date-from').value;
  const to = $('date-to').value;

  if (!from || !to) {
    return;
  }

  if (to < from) {
    showToast(
      'Дата окончания периода раньше даты начала.',
      true
    );
    return;
  }

  const difference = (
    new Date(`${to}T00:00:00`) -
    new Date(`${from}T00:00:00`)
  ) / 86400000;

  if (difference > 30) {
    showToast(
      'Можно выбрать период не более 31 дня.',
      true
    );
    return;
  }

  $('schedule-list').innerHTML =
    '<div class="empty-state">Загружаем расписание…</div>';

  $('period-label').textContent =
    formatPeriod(from, to);

  const params = new URLSearchParams({
    from,
    to,
    page: String(state.page),
    size: String(PAGE_SIZE),
  });

  if (
    state.user.role === 'ADMIN' &&
    $('filter-group').value
  ) {
    params.set('groupId', $('filter-group').value);
  }

  try {
    const result = await apiRequest(
      `/schedule?${params.toString()}`
    );

    state.entries = result.items || [];
    state.total = result.total || 0;

    renderSchedule();

    const pages = Math.max(
      1,
      Math.ceil(state.total / PAGE_SIZE)
    );

    $('result-count').textContent =
      `${state.total} ${pluralize(
        state.total,
        'занятие',
        'занятия',
        'занятий'
      )}`;

    $('page-info').textContent =
      `Страница ${result.page} из ${pages}`;

    $('previous-page').disabled =
      state.page <= 1;

    $('next-page').disabled =
      state.page >= pages;

  } catch (error) {
    if (state.user) {
      $('schedule-list').innerHTML =
        `<div class="empty-state">${escapeHtml(error.message)}</div>`;

      showToast(error.message, true);
    }
  }
}

function pluralize(number, one, few, many) {
  const n = Math.abs(number) % 100;
  const last = n % 10;

  if (n > 10 && n < 20) return many;
  if (last > 1 && last < 5) return few;
  if (last === 1) return one;

  return many;
}

function renderSchedule() {
  const list = $('schedule-list');

  list.replaceChildren();

  if (!state.entries.length) {
    list.innerHTML =
      '<div class="empty-state">На выбранный период занятий нет.</div>';
    return;
  }

  const groups = new Map();

  for (const entry of state.entries) {
    const key = localDateString(
      new Date(entry.startsAt)
    );

    if (!groups.has(key)) {
      groups.set(key, []);
    }

    groups.get(key).push(entry);
  }

  for (const [day, entries] of groups) {
    const heading = document.createElement('div');

    heading.className = 'day-heading';

    const date = new Date(`${day}T12:00:00`);

    heading.textContent = date.toLocaleDateString(
      'ru-RU',
      {
        weekday: 'long',
        day: 'numeric',
        month: 'long',
      }
    );

    list.append(heading);

    for (const entry of entries) {
      const [statusLabel, statusClass] =
        statusInfo(entry.status);

      const card = document.createElement('article');

      card.className = 'schedule-card';

      const teacher = entry.teacherName
        ? `<span>♙ ${escapeHtml(entry.teacherName)}</span>`
        : '';

      const group = entry.groupName
        ? `<span>▦ ${escapeHtml(entry.groupName)}</span>`
        : '';

      const actions = state.user.role === 'ADMIN'
        ? `
          <button
            class="button button-ghost button-small"
            type="button"
            data-action="edit"
            data-id="${escapeHtml(entry.id)}"
          >Изменить</button>

          ${
            String(entry.status).toLowerCase() === 'draft'
              ? `
                <button
                  class="button button-primary button-small"
                  type="button"
                  data-action="publish"
                  data-id="${escapeHtml(entry.id)}"
                >Опубликовать</button>
              `
              : ''
          }

          <button
            class="button button-ghost button-small"
            type="button"
            data-action="cancel"
            data-id="${escapeHtml(entry.id)}"
          >Отменить</button>
        `
        : '';

      card.innerHTML = `
        <div class="time-block">
          <strong>${formatTime(entry.startsAt)}</strong>
          <span>до ${formatTime(entry.endsAt)}</span>
        </div>

        <div class="lesson-main">
          <h3>${escapeHtml(entry.subjectName)}</h3>

          <div class="lesson-meta">
            ${group}
            <span>⌖ ${escapeHtml(entry.roomName)}</span>
            ${teacher}
          </div>
        </div>

        <div class="lesson-side">
          <span class="status ${statusClass}">
            ${statusLabel}
          </span>
          ${actions}
        </div>
      `;

      list.append(card);
    }
  }
}

// -------------------- Создание и редактирование --------------------

function setDefaultEntryTimes() {
  const start = new Date();

  start.setMinutes(0, 0, 0);
  start.setHours(start.getHours() + 1);

  const end = new Date(
    start.getTime() + 90 * 60000
  );

  $('entry-start').value =
    dateTimeLocalString(start);

  $('entry-end').value =
    dateTimeLocalString(end);
}

function openEditor() {
  state.editingId = null;

  $('entry-form').reset();
  $('entry-id').value = '';

  $('editor-title').textContent =
    'Новое занятие';

  $('editor-description').textContent =
    'Создайте занятие. Оно будет сохранено как черновик.';

  $('entry-group').disabled = false;
  $('entry-group-wrap').hidden = false;
  $('entry-error').hidden = true;
  $('admin-editor').hidden = false;

  setDefaultEntryTimes();

  $('admin-editor').scrollIntoView({
    behavior: 'smooth',
    block: 'start',
  });
}

function closeEditor() {
  $('admin-editor').hidden = true;
  state.editingId = null;
}

async function editEntry(id) {
  try {
    const entry = await apiRequest(
      `/schedule/${encodeURIComponent(id)}`
    );

    state.editingId = id;

    $('entry-id').value = id;

    $('editor-title').textContent =
      'Изменение занятия';

    $('editor-description').textContent =
      'Группа не изменяется. Публикация выполняется отдельной операцией.';

    $('entry-subject').value = entry.subjectId;
    $('entry-group').value = entry.groupId;
    $('entry-group').disabled = true;

    $('entry-group-wrap').hidden = false;

    $('entry-teacher').value =
      entry.teacherId || '';

    $('entry-room').value = entry.roomId;

    $('entry-start').value =
      dateTimeLocalString(new Date(entry.startsAt));

    $('entry-end').value =
      dateTimeLocalString(new Date(entry.endsAt));

    $('entry-error').hidden = true;
    $('admin-editor').hidden = false;

    $('admin-editor').scrollIntoView({
      behavior: 'smooth',
      block: 'start',
    });

  } catch (error) {
    showToast(error.message, true);
  }
}

// -------------------- Идемпотентность --------------------

function newIdempotencyKey() {
  if (
    window.crypto &&
    typeof window.crypto.randomUUID === 'function'
  ) {
    return window.crypto.randomUUID();
  }

  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(
    /[xy]/g,
    (char) => {
      const random = Math.random() * 16 | 0;

      return (
        char === 'x'
          ? random
          : (random & 0x3 | 0x8)
      ).toString(16);
    }
  );
}

// -------------------- Сохранение занятия --------------------

async function saveEntry(event) {
  event.preventDefault();

  const errorBox = $('entry-error');

  errorBox.hidden = true;

  const subjectId = $('entry-subject').value;
  const teacherId = $('entry-teacher').value || null;
  const roomId = $('entry-room').value;

  const startsAt = toApiDateTime(
    $('entry-start').value
  );

  const endsAt = toApiDateTime(
    $('entry-end').value
  );

  if (endsAt <= startsAt) {
    throw new Error(
      'Окончание занятия должно быть позже начала.'
    );
  }

  const wasEditing = Boolean(state.editingId);

  let path;
  let method;
  let body;

  const headers = {
    'Content-Type': 'application/json',
  };

  if (state.editingId) {
    path = `/schedule/${encodeURIComponent(state.editingId)}`;
    method = 'PATCH';

    body = {
      subjectId,
      teachedId: teacherId,
      roomId,
      startsAt,
      endsAt,
    };

  } else {
    path = '/schedule';
    method = 'POST';

    headers['Idempotency-Key'] =
      newIdempotencyKey();

    body = {
      subjectId,
      groupId: $('entry-group').value,
      teachedId: teacherId,
      roomId,
      startsAt,
      endsAt,
    };
  }

  try {
    await apiRequest(path, {
      method,
      headers,
      body: JSON.stringify(body),
    });

    closeEditor();

    showToast(
      wasEditing
        ? 'Изменения сохранены.'
        : 'Занятие создано как черновик.'
    );

    await loadSchedule();

  } catch (error) {
    errorBox.textContent = error.message;
    errorBox.hidden = false;
  }
}

// -------------------- Публикация --------------------

async function publishEntry(id) {
  if (
    !window.confirm(
      'Опубликовать занятие? Оно станет доступно участникам учебной группы.'
    )
  ) {
    return;
  }

  try {
    await apiRequest(
      `/schedule/${encodeURIComponent(id)}/publish`,
      {
        method: 'POST',
        headers: {
          'Idempotency-Key': newIdempotencyKey(),
        },
      }
    );

    showToast('Занятие опубликовано.');

    await loadSchedule();

  } catch (error) {
    showToast(error.message, true);
  }
}

// -------------------- Отмена занятия --------------------

async function cancelEntry(id) {
  if (
    !window.confirm(
      'Отменить это занятие? Оно исчезнет из обычного расписания.'
    )
  ) {
    return;
  }

  try {
    await apiRequest(
      `/schedule/${encodeURIComponent(id)}`,
      {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          status: 'cancelled',
        }),
      }
    );

    showToast('Занятие отменено.');

    await loadSchedule();

  } catch (error) {
    showToast(error.message, true);
  }
}

// -------------------- Выход --------------------

async function logout() {
  try {
    await apiRequest('/auth/logout', {
      method: 'POST',
    });

    state.user = null;

    showLogin('Вы вышли из системы.');

  } catch (error) {
    showToast(error.message, true);
  }
}

// -------------------- Начальный период --------------------

function setDefaultPeriod() {
  const today = new Date();

  const weekLater = new Date(today);

  weekLater.setDate(today.getDate() + 6);

  $('date-from').value =
    localDateString(today);

  $('date-to').value =
    localDateString(weekLater);
}

// -------------------- Обработчики событий --------------------

$('login-form').addEventListener(
  'submit',
  async (event) => {
    event.preventDefault();

    $('login-error').hidden = true;

    const button = $('login-form').querySelector(
      'button[type="submit"]'
    );

    button.disabled = true;

    try {
      await apiRequest('/auth/login', {
        method: 'POST',

        headers: {
          'Content-Type': 'application/json',
        },

        body: JSON.stringify({
          login: $('login').value.trim(),
          password: $('password').value,
        }),
      });

      await loadCurrentUser();

    } catch (error) {
      $('login-error').textContent =
        error.message;

      $('login-error').hidden = false;

    } finally {
      button.disabled = false;
    }
  }
);

$('logout-button').addEventListener(
  'click',
  logout
);

$('filter-form').addEventListener(
  'submit',
  (event) => {
    event.preventDefault();

    state.page = 1;

    loadSchedule();
  }
);

$('today-button').addEventListener(
  'click',
  () => {
    const today = localDateString();

    $('date-from').value = today;
    $('date-to').value = today;

    state.page = 1;

    loadSchedule();
  }
);

$('refresh-button').addEventListener(
  'click',
  loadSchedule
);

$('new-entry-button').addEventListener(
  'click',
  openEditor
);

$('close-editor-button').addEventListener(
  'click',
  closeEditor
);

$('cancel-editor-button').addEventListener(
  'click',
  closeEditor
);

$('entry-form').addEventListener(
  'submit',
  (event) => {
    saveEntry(event).catch((error) => {
      $('entry-error').textContent =
        error.message;

      $('entry-error').hidden = false;
    });
  }
);

$('previous-page').addEventListener(
  'click',
  () => {
    if (state.page > 1) {
      state.page -= 1;
      loadSchedule();
    }
  }
);

$('next-page').addEventListener(
  'click',
  () => {
    if (state.page * PAGE_SIZE < state.total) {
      state.page += 1;
      loadSchedule();
    }
  }
);

$('filter-group').addEventListener(
  'change',
  () => {
    state.page = 1;
    loadSchedule();
  }
);

$('schedule-list').addEventListener(
  'click',
  (event) => {
    const button = event.target.closest(
      'button[data-action]'
    );

    if (!button) {
      return;
    }

    const { action, id } = button.dataset;

    if (action === 'edit') {
      editEntry(id);
    }

    if (action === 'publish') {
      publishEntry(id);
    }

    if (action === 'cancel') {
      cancelEntry(id);
    }
  }
);

// -------------------- Запуск приложения --------------------

setDefaultPeriod();
loadCurrentUser();
