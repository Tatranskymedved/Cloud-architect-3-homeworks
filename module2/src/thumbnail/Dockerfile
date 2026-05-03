FROM python:3.11-slim

WORKDIR /app

# Install only the deps needed for the container (not azure-functions)
RUN pip install --no-cache-dir fastapi "uvicorn[standard]" Pillow

COPY app.py .

EXPOSE 80

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "80"]
