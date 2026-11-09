#!/usr/bin/env python3
import os
import sys
import json
import urllib.request
import urllib.error
import ssl
from concurrent.futures import ThreadPoolExecutor, as_completed
import psycopg2
from psycopg2.extras import RealDictCursor

# --- Configuration from Environment Variables ---
AUTHENTIK_URL = os.getenv("AUTHENTIK_URL", "https://sso.apex.lab").rstrip('/')
AUTHENTIK_TOKEN = os.getenv("AUTHENTIK_TOKEN")
DB_HOST = os.getenv("DB_HOST", "10.2.8.106")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "hr_db")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")

if not AUTHENTIK_TOKEN:
    print("[!] ERROR: AUTHENTIK_TOKEN environment variable is missing.")
    sys.exit(1)

# Disable SSL verification for internal self-signed certificates
ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE

HEADERS = {
    "Authorization": f"Bearer {AUTHENTIK_TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/json"
}

def http_request(url, method="GET", data=None, timeout=45):
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, context=ssl_ctx, timeout=timeout) as resp:
            if resp.status in (200, 201, 204):
                content = resp.read().decode("utf-8")
                return json.loads(content) if content else {}
    except urllib.error.HTTPError as e:
        if e.code in (400, 409):
            return {"status": "exists", "code": e.code}
        print(f"[!] HTTP Error {e.code} for {url}: {e.read().decode('utf-8')}")
    except Exception as e:
        print(f"[!] Request Exception for {url}: {e}")
    return None

def fetch_all_authentik_users():
    """Paginate through Authentik users in chunks of 1000 to prevent API timeouts."""
    all_users = []
    page = 1
    while True:
        url = f"{AUTHENTIK_URL}/api/v3/core/users/?page={page}&page_size=1000"
        res = http_request(url)
        if not res or "results" not in res:
            if page == 1:
                return None
            break
        all_users.extend(res.get("results", []))
        if not res.get("pagination", {}).get("next"):
            break
        page += 1
    return all_users

def fetch_all_authentik_groups():
    """Fetch all department groups from Authentik."""
    url = f"{AUTHENTIK_URL}/api/v3/core/groups/?page_size=1000"
    res = http_request(url)
    if not res or "results" not in res:
        return None
    return res.get("results", [])

def fetch_active_hr_users():
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute("""
            SELECT 
                username, 
                CONCAT(first_name, ' ', last_name) AS name, 
                email, 
                department
            FROM employees 
            WHERE status = 'ACTIVE';
        """)
        rows = cur.fetchall()
    conn.close()
    return rows

def main():
    print("[*] Fetching active HR employees from PostgreSQL...")
    active_users = fetch_active_hr_users()
    print(f"[+] Loaded {len(active_users)} active employee record(s).")

    print("[*] Pre-caching Authentik users and department groups...")
    authentik_users = fetch_all_authentik_users()
    authentik_groups = fetch_all_authentik_groups()

    if authentik_users is None or authentik_groups is None:
        print("[!] ERROR: Failed to fetch users or groups from Authentik API. Aborting execution.")
        sys.exit(1)

    user_map = {u["username"]: u for u in authentik_users}
    group_map = {g["name"]: g for g in authentik_groups}

    # 1. Evaluate User Creations & Re-activations
    users_to_create = []
    users_to_activate = []

    for u in active_users:
        uname = u["username"]
        if uname not in user_map:
            users_to_create.append(u)
        elif not user_map[uname].get("is_active", True):
            users_to_activate.append((user_map[uname]["pk"], uname))

    print(f"[*] Provisioning {len(users_to_create)} missing user(s) and activating {len(users_to_activate)} inactive user(s)...")

    def create_user(u):
        payload = {
            "username": u["username"],
            "name": u["name"],
            "email": u["email"],
            "is_active": True,
            "attributes": {"department": u["department"]}
        }
        res = http_request(f"{AUTHENTIK_URL}/api/v3/core/users/", method="POST", data=payload)
        return u["username"], res

    def activate_user(item):
        pk, uname = item
        payload = {"is_active": True}
        res = http_request(f"{AUTHENTIK_URL}/api/v3/core/users/{pk}/", method="PATCH", data=payload)
        return uname, res

    with ThreadPoolExecutor(max_workers=25) as executor:
        create_futures = [executor.submit(create_user, u) for u in users_to_create]
        activate_futures = [executor.submit(activate_user, item) for item in users_to_activate]
        for f in as_completed(create_futures + activate_futures):
            f.result()

    # 2. Refresh directory map for group bindings
    print("[*] Refreshing user directory map for group bindings...")
    refreshed_users = fetch_all_authentik_users()
    if refreshed_users is None:
        print("[!] ERROR: Failed to refresh user directory map from Authentik API.")
        sys.exit(1)

    refreshed_user_map = {u["username"]: u["pk"] for u in refreshed_users}

    # 3. Evaluate Group Bindings
    group_bind_tasks = []
    for u in active_users:
        uname = u["username"]
        dept = u["department"]
        user_pk = refreshed_user_map.get(uname)
        target_group = group_map.get(dept)

        if user_pk and target_group:
            existing_group_users = target_group.get("users", [])
            if user_pk not in existing_group_users:
                group_bind_tasks.append((target_group["pk"], user_pk, uname, dept))

    print(f"[*] Binding {len(group_bind_tasks)} user(s) to target department groups...")

    def bind_user_to_group(task):
        group_pk, user_pk, uname, dept = task
        res = http_request(f"{AUTHENTIK_URL}/api/v3/core/groups/{group_pk}/add_user/", method="POST", data={"pk": user_pk})
        return uname, dept, res

    with ThreadPoolExecutor(max_workers=25) as executor:
        bind_futures = [executor.submit(bind_user_to_group, task) for task in group_bind_tasks]
        for f in as_completed(bind_futures):
            f.result()

    print("[+] Authentik active user & group synchronization complete.")

if __name__ == "__main__":
    main()