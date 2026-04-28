COMPOSE = docker compose -f $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))/docker-compose.yml

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f

pull:
	cd ~/infra && git pull
	cd ~/izacdotcomapi && git pull
