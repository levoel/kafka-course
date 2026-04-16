FROM python:3.12-slim
LABEL maintainer="Kafka Deep-Dive Course"
RUN pip install --no-cache-dir kafka-python==2.0.6
WORKDIR /app
COPY exercises/ /app/exercises/
CMD ["bash"]
