# Secrets

Not in version control. Create before first start.

| File | Purpose | Generate with |
|------|---------|---------------|
| `jwt_secret.txt` | signs identity verification tokens | `openssl rand -hex 32` |
| `session_secret.txt` | signs session cookies | `openssl rand -hex 32` |
| `storage_encryption_key.txt` | encrypts sensitive columns in the database | `openssl rand -hex 32` |

Owned by UID 8000, mode 600 (directory 700). Editing with `sudo` makes them
root-owned and the container loses access silently.

Rotating `storage_encryption_key.txt` requires re-encrypting the database
first. Replacing the file alone leaves existing rows unreadable.
