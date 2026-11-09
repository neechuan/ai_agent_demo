source .venv/bin/activate

uvicorn app.main:app --app-dir backend --host 0.0.0.0 --port 8000
