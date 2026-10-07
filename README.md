# Lady of the Data Lake (LDLx)

<div align="center">

[![Build LDLx Kiosk ISO](https://github.com/mdbench/ldlx/actions/workflows/build_kiosk.yml/badge.svg)](https://github.com/mdbench/ldlx/actions/workflows/build_kiosk.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/mdbench/ldlx?color=blue&style=flat-square)](https://github.com/mdbench/ldlx/releases)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-yellow.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Debian%20Bookworm%20%7C%20Flutter%20--pi-orange?style=flat-square)](https://github.com/mdbench/ldlx)

</div>

<div align="center">
  <img src="https://raw.githubusercontent.com/mdbench/ldlx/refs/heads/main/demo1.jpg" alt="LDLx Demo Image of Initial Entry" width="100%" height="auto" />
</div>

Lady of the Data Lake (LDLx) is a dedicated operating system designed to host and manage databases natively. 

## The Need It Fills

Developers and small teams frequently rely on databases, but transitioning those databases into secure, production-grade environments usually requires complex server setups, cloud hosting contracts, and intricate networking configurations. 

LDLx solves this problem by functioning as a security-focused, dedicated database operating system. Instead of running a database as a background application inside a heavy general-purpose desktop or server OS, LDLx turns hardware into a streamlined, purpose-built database server.

## Key Features

* **Dedicated Database OS:** Runs directly on hardware as a lean operating system powered by flutter-pi, removing unnecessary desktop overhead and focusing all system resources on database performance.
* **Production-Grade Tunneling:** Designed to ship with native, built-in Cloudflare Tunnel support alongside other networking options. This allows users to take a local database and securely expose it for production use without managing static public IP addresses or complex firewall configurations.
* **Local-First Architecture:** Empowers users to maintain absolute physical and local control over their data while retaining the flexibility to scale to production networks instantly.
* **Lightweight and Fast:** Optimized for minimal resource consumption, making it ideal for edge computing, local servers, or dedicated hardware nodes.

## OS Installation

LDLx can be installed onto bare-metal hardware or run as a live image using the automated ISO builds. 

### Current Release
You can download the latest installable ISO image, automated release artifacts, and checksums directly from the [LDLx GitHub Releases Page](https://github.com/mdbench/ldlx/releases).

### Installation Instructions
1. **Download the ISO:** Visit https://github.com/mdbench/ldlx/releases and download the latest release asset.
2. **Flash to USB:** Flash the ISO image to a blank USB flash drive using Rufus, Ventoy, or dd.
3. **Boot Target Hardware:** Insert the USB into your target machine, boot into UEFI/BIOS settings, configure priority boot from USB, and launch the installer.
4. **Kiosk Auto-Login & Execution:** Upon completion and reboot, the system automatically launches into the secure LDLx environment on tty1 via openbox.
5. **Default Username/PW:** username: admin, password: admin

---

### Running via Docker (CLI)
You can load and run the container bundle directly from the command line using Docker:

```bash
    # 1. Load the container bundle tarball directly into Docker as an image
    docker load -i dockers/latest.tar.gz

    # 2. Run the container with GUI/X11 forwarding for local testing
    docker run --rm -it \
        -e DISPLAY=$DISPLAY \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        --device /dev/dri \
        --device /dev/snd \
        ldlx
```

### Running via Portainer (Docker Compose)
To deploy the kiosk container stack using Portainer or standard Docker Compose from the public repository, use the following configuration:

```yml
    version: '3.8'

    services:
      ldlx-kiosk:
        image: mdbench/ldlx-kiosk:latest
        container_name: ldlx-security-kiosk
        restart: unless-stopped
        environment:
          - DISPLAY=${DISPLAY:-:0}
          - GDK_SCALE=0.85
          - GDK_DPI_SCALE=0.85
        volumes:
          - /tmp/.X11-unix:/tmp/.X11-unix:ro
          - ldlx_data:/opt/ldlx/data
        devices:
          - /dev/dri:/dev/dri
          - /dev/snd:/dev/snd
        security_opt:
          - seccomp:unconfined
        build:
          context: https://github.com/mdbench/ldlx.git#main:dockers

    volumes:
      ldlx_data:
```

## LDLx API Documentation

The LDLx API (`DbServerManager`) exposes a secure HTTPS REST server running on port `9000` (by default) to manage local databases, rotate authentication tokens, and execute CRUD operations.

### Base URL & Protocol
* **Domain / Local URL:** `https://lakelady.ldlx:9000` or `https://<bound_ip>:9000`
* **Transport:** HTTPS / Secure JSON over SSL using local certificates (`assets/cert.pem` and `assets/key.pem`).
* **Required Authentication Headers:**
  * `Authorization: Bearer <jwt_token>` (Required for all `/api/data` endpoints, unless accessing from localhost loopback).
  * `X-Database-Name: <database_name>` (Required to target a specific local database file).

### Endpoints

#### 1. System Health Check
* **Endpoint:** `GET /health`
* **Description:** Retrieves server status, protocol, bound IP, domain, port, target database state, available databases, and current authentication validity.
* **Response Example:**
    ```json
    {
      "status": "UP",
      "protocol": "HTTPS",
      "server": "LDLx Unified Data Lake REST Server",
      "bound_ip": "192.168.1.50",
      "domain": "lakelady.ldlx",
      "port": 9000,
      "target_database": "core",
      "available_databases": ["core", "users", "analytics"],
      "authenticated": true
    }
    ```

#### 2. Rotate JWT Auth Token
* **Endpoint:** `POST /api/auth/token`
* **Description:** Generates a fresh cryptographic HS256 JWT token with full admin scope (`'scope': 'full_admin_access'`) and invalidates all prior tokens.
* **Response Example:**
    ```json
    {
      "status": "TOKEN_ROTATED",
      "message": "All previous tokens have been expired successfully.",
      "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJsZGx4LWRhdGEtbGFrZS1zZXJ2ZXIiLCJpYXQiOjE2ODAwMDAwMDB9.sig..."
    }
    ```

#### 3. Data CRUD Operations
* **Endpoint:** `/api/data` (Supports `GET`, `POST`, `PUT`, `DELETE`)
* **Required Headers:** 
  * `Authorization: Bearer <jwt_token>`
  * `X-Database-Name: <database_name>`

##### A. Query / Retrieve Data (`GET /api/data`)
* **Query Parameters (Optional):**
  * `table`: Target table name (if structured with tables).
  * `field` (or `column`, `key`): Field name to search.
  * `value`: Value to match.
* **Response Example (Matching Entry):**
    ```json
    {
      "database": "core",
      "query": {"field": "user_id"},
      "match": {
        "user_id": "1001",
        "name": "Operator"
      }
    }
    ```

##### B. Insert Record (`POST /api/data`)
* **Request Body:** JSON payload containing the record/document to insert.
* **Response Example:**
    ```json
    {
      "status": "CREATED",
      "database": "core",
      "inserted": {
        "id": "abc-123",
        "status": "active"
      }
    }
    ```

##### C. Update Database (`PUT /api/data`)
* **Request Body:** JSON override/update payload. Automatically records metadata (`last_updated_by`, `last_updated_time`, and `override_data`).
* **Response Example:**
    ```json
    {
      "status": "UPDATED",
      "database": "core",
      "data": {
        "last_updated_by": "Network_API_User",
        "last_updated_time": "2026-10-06T09:27:00.000Z",
        "override_data": { ... }
      }
    }
    ```

##### D. Delete Last Record (`DELETE /api/data`)
* **Description:** Removes the last record from the target table or document list.
* **Response Example:**
    ```json
    {
      "status": "DELETED_LAST_RECORD",
      "database": "core"
    }
    ```

## Roadmap

* Enforce better memory management, code reusability, and enhance core features.
* Add pro version subscription upgrade to free version for more advanced features.

## License

This project is open-source and released under the [GPL-3.0 license](LICENSE).