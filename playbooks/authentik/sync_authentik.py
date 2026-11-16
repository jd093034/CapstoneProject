#!/usr/bin/env python3
# The line above tells Linux to run this file using Python 3

# Built-in Python tools for reading settings, exiting early, handling JSON, making web calls, and timing retries
import os
import sys
import json
import urllib.request
import urllib.error
import ssl
import time
# Lets Python run multiple web requests at the exact same time instead of waiting one by one
from concurrent.futures import ThreadPoolExecutor, as_completed
# psycopg2 connects Python to PostgreSQL; RealDictCursor lets us read database columns by name (like u["username"])
import psycopg2
from psycopg2.extras import RealDictCursor

# --- Configuration from Environment Variables ---
# os.getenv("NAME", "backup") reads settings passed in privately by Ansible's environment block.
# .rstrip('/') removes any extra slash at the end of the URL so we don't get double slashes like "//api".
AUTHENTIK_URL = os.getenv("AUTHENTIK_URL", "http://10.2.8.105:9000").rstrip('/')
AUTHENTIK_TOKEN = os.getenv("AUTHENTIK_TOKEN")
DB_HOST = os.getenv("DB_HOST", "10.2.8.106")
# int(...) converts the port text "5432" into a real number
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "hr_db")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "MySecretAnsibleToken123!")

# Stop right away with error code 1 if Ansible forgot to pass the secret Authentik API token
if not AUTHENTIK_TOKEN:
    print("[!] ERROR: AUTHENTIK_TOKEN environment variable is missing.")
    sys.exit(1)

# Disable SSL verification for internal self-signed certificates
# Our isolated Proxmox lab uses a self-signed HTTPS certificate, so this tells Python not to block it
ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE

# HTTP headers sent with every web request: attaches our secret API token ("Bearer ...") and specifies JSON format
HEADERS = {
    "Authorization": f"Bearer {AUTHENTIK_TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/json"
}

# Reusable helper function that sends GET, POST, or PATCH web requests to Authentik's API
def http_request(url, method="GET", data=None, timeout=30, retries=3):
    """Executes HTTP requests with robust retry logic for transient API drops."""
    # If we are sending data (like creating a user), convert the Python dictionary into JSON text, then raw bytes
    body = json.dumps(data).encode("utf-8") if data else None
    
    # Try up to 3 times in case Authentik briefly hiccups under heavy load
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
        try:
            # Open the web connection and read the response
            with urllib.request.urlopen(req, context=ssl_ctx, timeout=timeout) as resp:
                # 200 = OK, 201 = Created, 204 = Success with empty response
                if resp.status in (200, 201, 204):
                    content = resp.read().decode("utf-8")
                    # Convert the JSON response text back into a Python dictionary (or {} if empty)
                    return json.loads(content) if content else {}
        except urllib.error.HTTPError as e:
            # 400/409 usually means "this user or group already exists"—not a crash, just return status="exists"
            if e.code in (400, 409):
                try:
                    content = e.read().decode("utf-8")
                    return {"status": "exists", "code": e.code, "details": json.loads(content)}
                except Exception:
                    return {"status": "exists", "code": e.code}
            # For temporary server errors, wait slightly longer each retry (0.2s, 0.4s) and try again
            if attempt < retries:
                time.sleep(0.2 * attempt)
        except Exception as e:
            # Catch network timeouts or connection drops and retry before giving up
            if attempt < retries:
                time.sleep(0.2 * attempt)
            else:
                print(f"[!] Request Exception for {url} after {retries} attempts: {e}")
    return None

def fetch_all_authentik_users():
    """Paginate through Authentik users in chunks of 1000 to prevent API timeouts."""
    all_users = []
    page = 1
    # Keep requesting pages of 1,000 users until Authentik says there is no "next" page
    while True:
        url = f"{AUTHENTIK_URL}/api/v3/core/users/?page={page}&page_size=1000"
        res = http_request(url)
        if not res or "results" not in res:
            # If page 1 fails completely, Authentik is unreachable—return None so main() aborts safely
            if page == 1:
                return None
            break
        # .extend() adds all users from this page onto the end of our master all_users list
        all_users.extend(res.get("results", []))
        if not res.get("pagination", {}).get("next"):
            break
        page += 1
    return all_users

def fetch_all_authentik_groups():
    """Fetch all security groups from Authentik in chunks of 1000."""
    all_groups = []
    page = 1
    # Same paging loop as users: grab 1,000 groups per page until there are no pages left
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
    # Open a connection to PostgreSQL
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )
    # RealDictCursor returns each database row as a dictionary so we can look up fields like row["email"]
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        # CONCAT(first_name, ' ', last_name) combines first and last name into one "name" column
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
    # .get("key", "default") safely reads a field without crashing if it's missing
    u_type = user.get("user_type", "STUDENT")
    school = user.get("school", "")
    grade = str(user.get("grade_level") or "N/A")

    # Assign district-wide, grade-level, and school-specific groups based on role
    if u_type == "STUDENT":
        groups.append("GRP_District_Students")
        
        # Grade group mapping (e.g., GRP_Grade_05)
        # .isdigit() checks if grade is a number; :02d pads single digits with a zero ("5" -> "05")
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

    # Pull all existing Authentik users and groups once upfront into memory for instant lookups
    print("[*] Pre-caching Authentik users and security groups...")
    authentik_users = fetch_all_authentik_users()
    authentik_groups = fetch_all_authentik_groups()

    # If Authentik's API didn't respond, exit with code 1 so Ansible marks the task failed
    if authentik_users is None or authentik_groups is None:
        print("[!] ERROR: Failed to fetch users or groups from Authentik API. Aborting execution.")
        sys.exit(1)

    # Fast lookup dictionaries:
    # user_map: username -> full Authentik user object
    # user_pk_map: username -> Authentik's internal numeric ID ("pk")
    # group_map: group name -> full Authentik group object
    user_map = {u["username"]: u for u in authentik_users}
    user_pk_map = {u["username"]: u["pk"] for u in authentik_users}
    group_map = {g["name"]: g for g in authentik_groups}

    # 0. Pre-create any missing GRP_ Security Groups in Authentik
    # set() holds unique items with no duplicates—collects every group name needed across all active users
    all_target_group_names = set()
    for u in active_users:
        all_target_group_names.update(get_target_k12_groups(u))

    # Filter down to only groups that don't exist in Authentik yet, and create them with POST
    missing_groups = [g_name for g_name in all_target_group_names if g_name not in group_map]
    if missing_groups:
        print(f"[*] Pre-creating {len(missing_groups)} missing K-12 security group(s) in Authentik...")
        for g_name in missing_groups:
            res = http_request(f"{AUTHENTIK_URL}/api/v3/core/groups/", method="POST", data={"name": g_name})
            if res and "pk" in res:
                group_map[g_name] = res

    # 1. Evaluate User Provisioning & Re-activations
    # Split active database users into two lists: brand-new users to create, and disabled users to turn back on
    users_to_create = []
    users_to_activate = []

    for u in active_users:
        uname = u["username"]
        if uname not in user_map:
            users_to_create.append(u)
        elif not user_map[uname].get("is_active", True):
            users_to_activate.append((user_map[uname]["pk"], uname))

    print(f"[*] Provisioning {len(users_to_create)} missing user(s) and activating {len(users_to_activate)} inactive user(s)...")

    # Worker function that sends a POST request to create one user in Authentik (with K-12 custom attributes)
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
        
        # Backup lookup: if the user already existed (400/409), query their numeric ID ("pk") so we can still add them to groups
        query_res = http_request(f"{AUTHENTIK_URL}/api/v3/core/users/?username={u['username']}")
        if query_res and query_res.get("results"):
            return u["username"], query_res["results"][0]["pk"]
            
        return u["username"], None

    # Worker function that re-enables a previously disabled user account via PATCH
    def activate_user(item):
        pk, uname = item
        payload = {"is_active": True}
        res = http_request(f"{AUTHENTIK_URL}/api/v3/core/users/{pk}/", method="PATCH", data=payload)
        return uname, pk, res

    # Run 25 parallel workers at once so creating/activating 1,000 users finishes in seconds
    with ThreadPoolExecutor(max_workers=25) as executor:
        # executor.submit() schedules all tasks; as_completed() collects each user's new "pk" as soon as it finishes
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
    # Build a dictionary mapping each group's ID (grp_pk) -> set of all user IDs (user_pk) that belong in it
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

    # Compare target members against current members; only update groups where someone is missing
    groups_to_update = []
    for grp_pk, target_u_pks in group_users_target.items():
        existing_pks = group_members_existing.get(grp_pk, set())
        if target_u_pks != existing_pks:
            # .union() merges existing members and new members together without losing anyone
            combined_pks = list(existing_pks.union(target_u_pks))
            groups_to_update.append((grp_pk, combined_pks))

    # Instead of 1,000+ individual "add user to group" web requests, we send ONE PATCH per group with its full member list
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

# Standard Python entry point: runs main() only when this file is executed directly
if __name__ == "__main__":
    main()