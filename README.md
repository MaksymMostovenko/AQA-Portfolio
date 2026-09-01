# Kanboard AQA Portfolio

Version-pinned local QA bootstrap for a Kanboard case study. This repository
currently provides the system under test: Kanboard, PostgreSQL, and a persistent
Jenkins controller. It is suitable for exploratory UI/API/DB work and for
designing the later automation architecture.

This is not a completed CI pipeline yet. Jenkins still requires its one-time
setup, and build toolchains will be added as separate agents/test-runner images
after the Feature Map, Scope, Risk Analysis, and Test Plan are defined.

## Stack

| Service | Pinned image | Host access | Access from Docker services |
| --- | --- | --- | --- |
| Kanboard | `kanboard/kanboard:v1.2.54` | <http://localhost:8080> | `http://kanboard/` |
| PostgreSQL | `postgres:17.11-alpine3.24` | `localhost:5432` | `postgres:5432` |
| Jenkins LTS | `jenkins/jenkins:2.568.2-jdk21` | <http://localhost:8081> | `http://jenkins:8080/` |

Host ports bind to `127.0.0.1`, so the services are not exposed to the local
network. Kanboard, PostgreSQL, Jenkins, plugins, and generated SSL material use
Docker named volumes.

## Prerequisites

- Docker Desktop running with Linux containers
- Docker Compose v2
- At least 4 GB of memory available to Docker (Jenkins benefits from more)

## First start

Run these commands from the repository root in PowerShell:

```powershell
Copy-Item docker/.env.example docker/.env
# Review docker/.env before starting the stack.
docker compose --env-file docker/.env -f docker/docker-compose.yml config --quiet
docker compose --env-file docker/.env -f docker/docker-compose.yml up -d --wait
docker compose --env-file docker/.env -f docker/docker-compose.yml ps
```

The local `docker/.env` file is ignored by Git. If a password contains `#` or
`$`, quote it according to Docker Compose `.env` rules. Set the database password
before the first start: changing `POSTGRES_PASSWORD` after the PostgreSQL volume
has been initialized does not change the existing database role password.

Kanboard's initial credentials are `admin` / `admin`. Change them after the
first login. Do not expose this development stack beyond localhost without
replacing all default credentials and adding an appropriate TLS/reverse-proxy
configuration.

## Jenkins setup

Retrieve the one-time setup password before completing the setup wizard:

```powershell
docker compose --env-file docker/.env -f docker/docker-compose.yml exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

The Jenkins controller intentionally does not contain Python, Maven, Docker CLI,
Allure, or a browser. Builds should run on pinned agents/test-runner images, not
on the controller. The future CI design must keep the persistent Jenkins
controller separate from the ephemeral Kanboard/PostgreSQL SUT lifecycle so a
pipeline cannot stop or delete its own controller.

## Service checks

From the Windows host:

```powershell
Invoke-WebRequest http://localhost:8080/healthcheck.php -UseBasicParsing
Invoke-WebRequest http://localhost:8081/login -UseBasicParsing
```

From Jenkins or another container on `qa_network`, Kanboard's database-aware
health endpoint is `http://kanboard/healthcheck.php`, not `localhost:8080`.

JSON-RPC endpoints:

```text
Host:             http://localhost:8080/jsonrpc.php
Docker network:   http://kanboard/jsonrpc.php
```

For DBeaver or host-side `psql`, use host `localhost`, port `5432`, and the
PostgreSQL values from `docker/.env`. Containerized tests use host `postgres`
and port `5432`.

## Automated smoke check

Run the host-side smoke suite after starting or changing the environment:

```powershell
.\scripts\smoke-environment.ps1
```

It validates Docker/Compose, all three container healthchecks, host HTTP,
Jenkins-to-Kanboard networking, the PostgreSQL schema, and the Jenkins port
boundary. Published ports are discovered from Docker, so custom values from
`docker/.env` are supported.

The authenticated JSON-RPC `getVersion` check is optional. Supply credentials
as an in-memory `PSCredential` without writing them to the repository:

```powershell
$credential = Get-Credential -UserName 'admin' -Message 'Kanboard API credentials'
.\scripts\smoke-environment.ps1 -KanboardApiCredential $credential
Remove-Variable credential
```

## Logs and lifecycle

```powershell
# Follow all logs
docker compose --env-file docker/.env -f docker/docker-compose.yml logs -f

# Stop containers and keep all test data
docker compose --env-file docker/.env -f docker/docker-compose.yml down

# Start the same environment again
docker compose --env-file docker/.env -f docker/docker-compose.yml up -d --wait
```

To reset the environment completely, use `down --volumes`. This permanently
deletes Kanboard, PostgreSQL, Jenkins, plugin, and generated SSL data owned by
this Compose project. Do not run it against an environment containing data you
need to preserve.

## Current architecture

```text
Windows host
  |-- http://localhost:8080 ------> Kanboard
  |-- localhost:5432 -------------> PostgreSQL
  `-- http://localhost:8081 ------> Jenkins controller

Docker qa_network
  Jenkins / future runners --http://kanboard/--> Kanboard --> PostgreSQL
```

The next project step is Feature Map + Scope + Risk Analysis, followed by the
Test Plan. Postman, Python API, Java/Selenide UI, Allure, Jenkins agents, and the
pipeline come after the test design establishes what should be automated.

## References

- [Kanboard Docker documentation](https://docs.kanboard.org/v1/admin/docker/)
- [Kanboard JSON-RPC API](https://docs.kanboard.org/v1/api/)
- [Official Jenkins Docker image](https://github.com/jenkinsci/docker)
- [Jenkins best practices](https://www.jenkins.io/doc/book/using/best-practices/)
