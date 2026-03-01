cd D:\IdeaProjects\startap\infrastructure\docker-compose\bitdive-llm

docker build -f Dockerfile -t frolikoveabitdive/bitdive-llm:latest .
docker push frolikoveabitdive/bitdive-llm:latest