# Generic image for one Flask challenge. The build context is target/, so
# APP_PATH (e.g. apps/example_challenge) selects which app goes in.
# An app can ship its own requirements.txt; Flask is always installed.
# Need OS packages too (e.g. iputils-ping for a ping-tool challenge)? Add an
# `apt-get install` line here.
FROM python:3.12-slim

ARG APP_PATH
RUN pip install --no-cache-dir flask

WORKDIR /app
COPY ${APP_PATH}/ /app/
COPY deploy/run.py /app/run.py
RUN if [ -f requirements.txt ]; then pip install --no-cache-dir -r requirements.txt; fi

CMD ["python3", "run.py"]
