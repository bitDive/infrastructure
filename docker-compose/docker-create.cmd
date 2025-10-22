cd D:\IdeaProjects\startap\infrastructure\docker-compose

docker build -f DockerfilePostgres -t frolikoveabitdive/bitdive-postgres:latest .
docker push frolikoveabitdive/bitdive-postgres:latest


docker build -f DockerfileVault -t frolikoveabitdive/bitdive-vault:latest .
docker push frolikoveabitdive/bitdive-vault:latest