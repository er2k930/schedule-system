### absolute vibecoding

## how-to

```bash
# после создания .env с обязательными значениями
docker compose up -d --build
docker compose ps
curl http://localhost:8000/health
```

```bash
# остановка без удаления данных
docker compose down
```

```bash
# полный сброс локальной БД и повторная инициализация
docker compose down -v
docker compose up -d --build
```