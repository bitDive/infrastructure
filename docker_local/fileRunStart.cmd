cd D:\IdeaProjects\startap\infrastructure>
docker build -t frolikoveabitdive/bitdive-launcher:latest -f docker_local/Dockerfile .
docker push frolikoveabitdive/bitdive-launcher:latest
docker run -d --privileged -p 443:443 --name bitdive-launcher frolikoveabitdive/bitdive-launcher:latest