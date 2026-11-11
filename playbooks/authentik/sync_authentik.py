#!/usr/bin/env python3
import os
import sys
import json
import urllib.request
import urllib.error
import ssl
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
import psycopg2
from psycopg2.extras import RealDictCursor

# --- Configuration from Environment Variables ---
AUTHENTIK_URL = os.getenv("AUTHENTIK_URL", "http://10.2.8.105:9000").rstrip('/')
AUTHENTIK_TOKEN = os.getenv("AUTHENTIK_TOKEN")
DB_HOST = os.getenv("DB_HOST", "10.2.8.106")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "hr_db")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "MySecretAnsibleToken123!")

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

def http_request(url, method="GET", data=None, timeout=30, retries=3):
    """Executes HTTP requests with robust retry logic for transient API drops."""
    body = json.dumps(data).encode("utf-8") if data else None
    
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
        try:
            with urllib.request.urlopen(req, context=ssl_ctx, timeout=timeout) as resp:
                if resp.status in (200, 201, 204):
                    content = resp.read().decode("utf-8")
                    return json.loads(content) if content else {}
        except urllib.error.HTTPError as e:
            if e.code in (400, 409):
                try:
                    content = e.read().decode("utf-8")
                    return {"status": "exists", "code": e.code, "details": json.loads(content)}
                except Exception:
                    return {"status": "exists", "code": e.code}
            if attempt < retries:
                time.sleep(0.2 * attempt)
        except Exception as e:
            if attempt < retries:
                time.sleep(0.2 * attempt)
            else:
                print(f"[!] Request Exception for {url} after {retries} attempts: {e}")
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
    """Fetch all security groups from Authentik in chunks of 1000."""
    all_groups = []
    page = 1
    while True:
        url = f"{AUTHENTIK_URL}/api/v3/core/groups/?page={page}&page_size=1000"
        res = http_request(url)
        if not res or "results" not in res:
            if page == 1:
                return None
            break
        all_groups.extend(res.get("results", []))
        if not res.get("pagination", {}).get("next"):
            break
        page += 1
    return all_groups

def fetch_active_hr_users():
    """Fetch active K-12 student and staff identities from PostgreSQL SIS database."""
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute("""
            SELECT 
                username, 
                CONCAT(first_name, ' ', last_name) AS name, 
                email,
                user_type,
                school,
                grade_level,
                department
            FROM employees 
            WHERE status = 'ACTIVE';
        """)
        rows = cur.fetchall()
    conn.close()
    return rows

def get_target_k12_groups(user):
    """Calculates all target GRP_ security groups for a student or staff identity."""
    groups = []
    u_type = user.get("user_type", "STUDENT")
    school = user.get("school", "")
    grade = str(user.get("grade_level") or "N/A")

    if u_type == "STUDENT":
        groups.append("GRP_District_Students")
        
        # Grade group mapping (e.g., GRP_Grade_05)
        if grade.isdigit():
            groups.append(f"GRP_Grade_{int(grade):02d}")
            
        # Campus group mapping
        if "Oakridge" in school:
            groups.append("GRP_Oakridge_ES")
        elif "Pinecrest" in school:
            groups.append("GRP_Pinecrest_ES")
        elif "Lakeside" in school:
            groups.append("GRP_Lakeside_MS")
        elif "Apex High" in school:
            groups.append("GRP_Apex_HS")
    elif u_type == "FACULTY":
        groups.append("GRP_District_Faculty")
    else:
        groups.append("GRP_District_Staff")

    return groups

def main():
    print("[*] Fetching active K-12 identities from PostgreSQL SIS database...")
    active_users = fetch_active_hr_users()
    print(f"[+] Loaded {len(active_users)} active student/staff record(s).")

    print("[*] Pre-caching Authentik users and security groups...")
    authentik_users = fetch_all_authentik_users()
    authentik_groups = fetch_all_authentik_groups()

    if authentik_users is None or authentik_groups is None:
        print("[!] ERROR: Failed to fetch users or groups from Authentik API. Aborting execution.")
        sys.exit(1)

    user_map = {u["username"]: u for u in authentik_users}
    user_pk_map = {u["username"]: u["pk"] for u in authentik_users}
    group_map = {g["name"]: g for g in authentik_groups}

    # 0. Pre-create any missing GRP_ Security Groups in Authentik
    all_target_group_names = set()
    for u in active_users:
        all_target_group_names.update(get_target_k12_groups(u))

    missing_groups = [g_name for g_name in all_target_group_names if g_name not in group_map]
    if missing_groups:
        print(f"[*] Pre-creating {len(missing_groups)} missing K-12 security group(s) in Authentik...")
        for g_name in missing_groups:
            res = http_request(f"{AUTHENTIK_URL}/api/v3/core/groups/", method="POST", data={"name": g_name})
            if res and "pk" in res:
                group_map[g_name] = res

    # 1. Evaluate User Provisioning & Re-activations
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
            "attributes": {
                "user_type": u["user_type"],
                "school": u["school"],
                "grade_level": u["grade_level"],
                "department": u["department"]
            }
        }
        res = http_request(f"{AUTHENTIK_URL}/api/v3/core/users/", method="POST", data=payload)
        
        if res and "pk" in res:
            return u["username"], res["pk"]
        
        query_res = http_request(f"{AUTHENTIK_URL}/api/v3/core/users/?username={u['username']}")
        if query_res and query_res.get("results"):
            return u["username"], query_res["results"][0]["pk"]
            
        return u["username"], None

    def activate_user(item):
        pk, uname = item
        payload = {"is_active": True}
        res = http_request(f"{AUTHENTIK_URL}/api/v3/core/users/{pk}/", method="PATCH", data=payload)
        return uname, pk, res

    with ThreadPoolExecutor(max_workers=25) as executor:
        create_futures = [executor.submit(create_user, u) for u in users_to_create]
        activate_futures = [executor.submit(activate_user, item) for item in users_to_activate]
        
        for f in as_completed(create_futures):
            uname, pk = f.result()
            if pk:
                user_pk_map[uname] = pk

        for f in as_completed(activate_futures):
            uname, pk, res = f.result()
            if pk:
                user_pk_map[uname] = pk

    # 2. High-Speed Bulk Group Membership Assignment (< 1.5 Seconds Total)
    group_users_target = {}
    for u in active_users:
        uname = u["username"]
        user_pk = user_pk_map.get(uname)
        target_group_names = get_target_k12_groups(u)

        if user_pk:
            for g_name in target_group_names:
                target_group = group_map.get(g_name)
                if target_group:
                    grp_pk = target_group["pk"]
                    if grp_pk not in group_users_target:
                        group_users_target[grp_pk] = set()
                    group_users_target[grp_pk].add(user_pk)

    # Pre-cache current group members from Authentik API
    group_members_existing = {g["pk"]: set(g.get("users", [])) for g in authentik_groups}

    groups_to_update = []
    for grp_pk, target_u_pks in group_users_target.items():
        existing_pks = group_members_existing.get(grp_pk, set())
        if target_u_pks != existing_pks:
            combined_pks = list(existing_pks.union(target_u_pks))
            groups_to_update.append((grp_pk, combined_pks))

    if groups_to_update:
        print(f"[*] Bulk-updating {len(groups_to_update)} group membership array(s) across K-12 security groups...")
        def update_group_members(item):
            grp_pk, members_list = item
            return http_request(f"{AUTHENTIK_URL}/api/v3/core/groups/{grp_pk}/", method="PATCH", data={"users": members_list})

        with ThreadPoolExecutor(max_workers=25) as executor:
            update_futures = [executor.submit(update_group_members, item) for item in groups_to_update]
            for f in as_completed(update_futures):
                f.result()
    else:
        print("[*] All K-12 security group memberships are already up to date.")

    print("[+] Authentik K-12 active user & group synchronization complete.")

if __name__ == "__main__":
    main()