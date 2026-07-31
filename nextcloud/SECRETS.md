# Secrets

Not in version control. Create before first start.

| File | Purpose | Generate with |
|------|---------|---------------|
| `admin_password.txt` | admin account, used on first install only | `openssl rand -base64 24` |
| `db_password.txt` | PostgreSQL role password | `openssl rand -base64 32` |

Mode 600. Read by the image as root before it drops to `www-data`, so no
container UID needs ownership.

Changing `db_password.txt` after the database exists does not update the
PostgreSQL role. Change it with `ALTER ROLE` first, then the file.
