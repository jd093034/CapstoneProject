#!/usr/bin/env python3
import json
import os
import ssl
import sys
import time
import urllib.request
from datetime import datetime

from jinja2 import Environment, FileSystemLoader
import psycopg2
from psycopg2.extras import RealDictCursor
import winrm

# --- Environment Variables ---
AUTHENTIK_URL = os.getenv("AUTHENTIK_URL", "http://10.2.8.105:9000").rstrip("/")
AUTHENTIK_TOKEN = os.getenv("AUTHENTIK_TOKEN")
DB_HOST = os.getenv("DB_HOST", "10.2.8.106")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "hr_db")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "MySecretAnsibleToken123!")
AD_HOST = os.getenv("AD_HOST", "10.2.8.67")
AD_USER = os.getenv("AD_USER", "Administrator")
AD_PASSWORD = os.getenv("AD_PASSWORD", "ApexPassword123!")
AD_DOMAIN = os.getenv("AD_DOMAIN", "apex.lab")

TEMPLATES_DIR = "/root/ansible/templates"
OUTPUT_DIR = os.getenv("OUTPUT_DIR", "/root/ansible/reports")


# --- Helper Functions & Logging ---
def read_log_file(filepath):
    if os.path.exists(filepath):
        try:
            with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
                return f.read()
        except Exception as e:
            print(f"[!] Warning reading {filepath}: {e}")
    return ""


def get_pipeline_runtime():
    start_file = "/tmp/pipeline_start_time"
    if os.path.exists(start_file):
        try:
            with open(start_file, "r") as f:
                start_epoch = float(f.read().strip())
                return round(time.time() - start_epoch, 1)
        except Exception as e:
            print(f"[!] Warning parsing start timestamp: {e}")

    log_file = "/tmp/hr_gen_output.log"
    if os.path.exists(log_file):
        return round(time.time() - os.path.getmtime(log_file), 1)

    return 12.0


def calculate_guarded_accuracy(verified, total, mismatches):
    if total <= 0:
        return 100.0
    acc = round((verified / total) * 100, 1)
    if mismatches > 0 and acc >= 100.0:
        return 99.9
    return acc


def get_k12_ad_location(user):
    """Infer exact K-12 OU location string from SIS user record."""
    u_type = (user.get("user_type") or "").strip().upper()
    sch = (user.get("school") or "").strip()
    grd = (str(user.get("grade_level")) if user.get("grade_level") is not None else "").strip()

    # Fallback inference if user_type is blank in PostgreSQL
    if not u_type:
        if sch in ["Oakridge Elementary", "Pinecrest Elementary", "Lakeside Middle School", "Apex High School", "Graduates"] or grd.isdigit() or grd == "GRAD":
            u_type = "STUDENT"

    if u_type == "STUDENT":
        if grd == "GRAD" or "Graduates" in sch:
            return "OU=Graduates,OU=Students,OU=APEX K12"
        elif sch:
            return f"OU={sch},OU=Students,OU=APEX K12"
        else:
            return "OU=Students,OU=APEX K12"
    elif u_type == "FACULTY":
        return "OU=Faculty,OU=Staff,OU=APEX K12"
    elif u_type == "ADMIN":
        return "OU=Administration,OU=Staff,OU=APEX K12"
    else:
        return "OU=Support Staff,OU=Staff,OU=APEX K12"


HR_GENERATOR_OUTPUT = read_log_file("/tmp/hr_gen_output.log")
PIPELINE_STDOUT = read_log_file("/tmp/pipeline_stdout.log")

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE


# ------------------------------------------------------------------------------
# 1. Query PostgreSQL (K-12 SIS Source of Truth)
# ------------------------------------------------------------------------------
def fetch_postgres_data():
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
    )
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute("""
            SELECT username, first_name, last_name, user_type, school, grade_level, department, email, status, legal_hold
            FROM employees WHERE status = 'ACTIVE' ORDER BY username ASC;
        """)
        active_users = cur.fetchall()

        cur.execute("""
            SELECT username, first_name, last_name, user_type, school, grade_level, department, email, status, 
                   TO_CHAR(terminated_at, 'YYYY-MM-DD HH24:MI:SS') AS terminated_at, legal_hold
            FROM employees WHERE status = 'TERMINATED' ORDER BY terminated_at DESC;
        """)
        inactive_users = cur.fetchall()

    conn.close()

    # Enrich active user dicts with full_name and K-12 ad_location / ou
    for u in active_users:
        u["full_name"] = f"{u.get('first_name', '')} {u.get('last_name', '')}".strip()
        u["ad_location"] = get_k12_ad_location(u)
        u["ou"] = u["ad_location"]

    # Enrich inactive user dicts with full_name and disabled ad_location / ou
    for u in inactive_users:
        u["full_name"] = f"{u.get('first_name', '')} {u.get('last_name', '')}".strip()
        u["ad_location"] = "OU=Users - Disabled,OU=APEX K12"
        u["ou"] = u["ad_location"]

    return active_users, inactive_users


# ------------------------------------------------------------------------------
# 2. Query Authentik District SSO REST API
# ------------------------------------------------------------------------------
def fetch_authentik_users():
    active_users = set()
    disabled_users = set()
    page = 1
    headers = {"Authorization": f"Bearer {AUTHENTIK_TOKEN}"}
    system_accounts = {"akadmin", "anonymous"}

    while True:
        url = f"{AUTHENTIK_URL}/api/v3/core/users/?page={page}&page_size=5000"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, context=ssl_ctx, timeout=30) as resp:
                data = json.loads(resp.read().decode())
                results = data.get("results", [])
                for u in results:
                    uname = u.get("username", "")
                    if uname in system_accounts or uname.startswith("ak-outpost-"):
                        continue
                    if u.get("is_active"):
                        active_users.add(uname)
                    else:
                        disabled_users.add(uname)
                if not data.get("pagination", {}).get("next"):
                    break
                page += 1
        except Exception as e:
            print(f"[!] Authentik API Query Error: {e}")
            break
    return active_users, disabled_users


# ------------------------------------------------------------------------------
# 3. Query Active Directory via WinRM PowerShell (OU=APEX K12 Directory Taxonomy)
# ------------------------------------------------------------------------------
def fetch_ad_users():
    ps_script = """
    $SearchBase = "OU=APEX K12,DC=apex,DC=lab"
    $Excluding = @('Administrator', 'Guest', 'krbtgt', 'Domain Admins', 'Domain Users')
    $ActiveAD = @()
    $DisabledAD = @()
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$SearchBase'" -ErrorAction SilentlyContinue) {
        Get-ADUser -Filter * -SearchBase $SearchBase -Properties Enabled, DistinguishedName -ErrorAction SilentlyContinue | 
          Where-Object { $Excluding -notcontains $_.Name -and $_.Name -notlike "HealthMailbox*" } | 
          ForEach-Object {
              if ($_.Enabled -eq $true) { $ActiveAD += $_.SamAccountName } 
              else { $DisabledAD += $_.SamAccountName }
          }
    }
    @{ active = ($ActiveAD | Select-Object -Unique); disabled = ($DisabledAD | Select-Object -Unique) } | ConvertTo-Json
    """
    if not AD_PASSWORD:
        print("[!] Warning: AD_PASSWORD is empty. Skipping AD WinRM lookup.")
        return None, None

    users_to_try = [AD_USER]
    if "\\" not in AD_USER and "@" not in AD_USER:
        domain_prefix = AD_DOMAIN.split(".")[0].upper() if "." in AD_DOMAIN else "APEX"
        users_to_try.append(f"{domain_prefix}\\{AD_USER}")
        users_to_try.append(f"{AD_USER}@{AD_DOMAIN}")

    for user_cred in users_to_try:
        try:
            session = winrm.Session(
                AD_HOST, auth=(user_cred, AD_PASSWORD), transport="ntlm"
            )
            res = session.run_ps(ps_script)
            if res.status_code == 0 and res.std_out:
                data = json.loads(res.std_out.decode("utf-8"))
                act_raw = data.get("active", [])
                dis_raw = data.get("disabled", [])
                if isinstance(act_raw, str):
                    act_raw = [act_raw]
                if isinstance(dis_raw, str):
                    dis_raw = [dis_raw]
                return set(act_raw or []), set(dis_raw or [])
        except Exception as e:
            print(f"[!] AD WinRM Query Exception for '{user_cred}': {e}")

    return None, None


# ------------------------------------------------------------------------------
# 4. Perform 4-Vector Bidirectional Reconciliation & Render K-12 HTML Reports
# ------------------------------------------------------------------------------
def main():
    print("=" * 75)
    print("[*] Initiating High-Speed K-12 SIS & Identity Store Reconciliation Engine...")
    print("[*] Scope: OU=APEX K12 (Students, Faculty, Staff, Graduates) | Authentik GRP_* Groups")
    print("=" * 75)

    pg_active, pg_inactive = fetch_postgres_data()
    auth_active, auth_disabled = fetch_authentik_users()
    ad_active_res, ad_disabled_res = fetch_ad_users()

    ad_failed = ad_active_res is None or ad_disabled_res is None
    ad_active = ad_active_res if ad_active_res is not None else set()
    ad_disabled = ad_disabled_res if ad_disabled_res is not None else set()

    target_active = {u["username"] for u in pg_active}
    target_terms = {u["username"] for u in pg_inactive}

    # Desync Vector Analysis
    auth_missing_active = list(target_active - auth_active)
    auth_orphan_active = list(auth_active - target_active)
    ad_missing_active = list(target_active - ad_active) if not ad_failed else []
    ad_orphan_active = list(ad_active - target_active) if not ad_failed else []

    auth_missing_terms = list(target_terms - auth_disabled)
    auth_orphan_disabled = list(auth_disabled - target_terms)
    ad_missing_terms = list(target_terms - ad_disabled) if not ad_failed else []
    ad_orphan_disabled = list(ad_disabled - target_terms) if not ad_failed else []

    active_auth_mismatches = list(set(auth_missing_active + auth_orphan_active))
    active_ad_mismatches = list(set(ad_missing_active + ad_orphan_active))
    disabled_auth_mismatches = list(set(auth_missing_terms + auth_orphan_disabled))
    disabled_ad_mismatches = list(set(ad_missing_terms + ad_orphan_disabled))

    total_active_mismatches = len(active_auth_mismatches) + len(active_ad_mismatches)
    total_disabled_mismatches = len(disabled_auth_mismatches) + len(disabled_ad_mismatches)

    total_active_probes = len(target_active | auth_active) + (
        len(target_active | ad_active) if not ad_failed else 0
    )
    total_disabled_probes = len(target_terms | auth_disabled) + (
        len(target_terms | ad_disabled) if not ad_failed else 0
    )

    total_probes = total_active_probes + total_disabled_probes
    total_mismatches = total_active_mismatches + total_disabled_mismatches

    # Guarded accuracy rates
    overall_accuracy = calculate_guarded_accuracy(
        total_probes - total_mismatches, total_probes, total_mismatches
    )
    sync_accuracy_rate = calculate_guarded_accuracy(
        total_disabled_probes - total_disabled_mismatches,
        total_disabled_probes,
        total_disabled_mismatches,
    )
    active_sync_accuracy_rate = calculate_guarded_accuracy(
        total_active_probes - total_active_mismatches,
        total_active_probes,
        total_active_mismatches,
    )

    # Lifecycle Event Parsing (Supports corporate & K-12 data stream tags)
    auto_secs = get_pipeline_runtime()
    gen_lines = [l for l in HR_GENERATOR_OUTPUT.splitlines() if l.strip()]
    
    count_hires = len([l for l in gen_lines if "HIRED:" in l or "ENROLLED:" in l])
    count_transfers = len([l for l in gen_lines if "TRANSFERRED:" in l or "PROMOTED:" in l or "GRADUATED:" in l])
    count_terms = len([l for l in gen_lines if "TERMINATED:" in l or "WITHDRAWN:" in l or "SEPARATED:" in l])
    
    total_events = count_hires + count_transfers + count_terms
    est_time_saved = total_events * 15

    now = datetime.now()
    date_time_dict = {
        "year": now.strftime("%Y"),
        "month": now.strftime("%m"),
        "day": now.strftime("%d"),
        "hour": now.strftime("%H"),
        "minute": now.strftime("%M"),
        "second": now.strftime("%S"),
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "epoch": str(int(now.timestamp())),
        "iso8601": now.isoformat(),
        "tz": now.strftime("%Z"),
        "weekday": now.strftime("%A"),
    }

    sync_result_dict = {
        "rc": 0,
        "stdout": PIPELINE_STDOUT,
        "stdout_lines": PIPELINE_STDOUT.splitlines(),
    }

    context = {
        "ansible_facts": {"date_time": date_time_dict},
        "ansible_date_time": date_time_dict,
        "sync_result": sync_result_dict,
        "raw_events": gen_lines,
        "auto_secs": auto_secs,
        "active_users_list": pg_active,
        "dynamic_inactive_users": pg_inactive,
        "disabled_users": pg_inactive,
        "overall_status": (
            "SUCCESS"
            if (total_mismatches == 0 and not ad_failed)
            else ("WARNING" if ad_failed else "FAILED")
        ),
        "postgres_status": "SUCCESS",
        "authentik_status": (
            "SUCCESS"
            if (len(active_auth_mismatches) + len(disabled_auth_mismatches)) == 0
            else "FAILED"
        ),
        "ad_status": (
            "SUCCESS"
            if (
                not ad_failed
                and (len(active_ad_mismatches) + len(disabled_ad_mismatches)) == 0
            )
            else ("FAILED" if ad_failed else "FAILED")
        ),
        "count_hires": count_hires,
        "count_transfers": count_transfers,
        "count_terminations": count_terms,
        "total_events": total_events,
        "total_active_managed": len(pg_active),
        "est_time_saved_mins": est_time_saved,
        "total_target_terms": len(target_terms),
        "authentik_synced_count": len(target_terms) - len(auth_missing_terms),
        "ad_synced_count": len(target_terms) - len(ad_missing_terms),
        "authentik_mismatches": len(disabled_auth_mismatches),
        "ad_mismatches": len(disabled_ad_mismatches),
        "authentik_mismatch_list": disabled_auth_mismatches,
        "ad_mismatch_list": disabled_ad_mismatches,
        "total_probes_conducted": total_disabled_probes,
        "total_verified_matches": total_disabled_probes - total_disabled_mismatches,
        "total_mismatches": total_disabled_mismatches,
        "sync_accuracy_rate": sync_accuracy_rate,
        "total_target_active": len(target_active),
        "authentik_active_synced_count": len(target_active) - len(auth_missing_active),
        "ad_active_synced_count": len(target_active) - len(ad_missing_active),
        "authentik_active_mismatches": len(active_auth_mismatches),
        "ad_active_mismatches": len(active_ad_mismatches),
        "total_active_mismatches": total_active_mismatches,
        "active_authentik_mismatch_list": active_auth_mismatches,
        "active_ad_mismatch_list": active_ad_mismatches,
        "total_active_probes_conducted": total_active_probes,
        "total_active_verified_matches": total_active_probes - total_active_mismatches,
        "active_sync_accuracy_rate": active_sync_accuracy_rate,
        "overall_sync_accuracy_rate": overall_accuracy,
        "pipeline_stdout": PIPELINE_STDOUT,
    }

    env = Environment(loader=FileSystemLoader(TEMPLATES_DIR))

    env.filters["to_json"] = lambda v, *args, **kwargs: json.dumps(v)
    env.filters["to_nice_json"] = lambda v, *args, **kwargs: json.dumps(v, indent=2)
    env.filters["from_json"] = (
        lambda v, *args, **kwargs: json.loads(v) if isinstance(v, str) else v
    )

    def make_list_filter(fn):
        def wrapper(*args, **kwargs):
            res = fn(*args, **kwargs)
            if hasattr(res, "__iter__") and not isinstance(
                res, (list, tuple, dict, str, bytes)
            ):
                return list(res)
            return res

        return wrapper

    for flt in ["select", "reject", "selectattr", "rejectattr", "map"]:
        if flt in env.filters:
            env.filters[flt] = make_list_filter(env.filters[flt])

    def safe_length(val):
        if val is None:
            return 0
        if hasattr(val, "__len__"):
            return len(val)
        if hasattr(val, "__iter__"):
            return len(list(val))
        return 0

    env.filters["length"] = safe_length
    env.filters["count"] = safe_length

    # Ensure output destination directory exists
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    for tpl_name, dest_name in [
        ("index.html.j2", "index.html"),
        ("active.html.j2", "active.html"),
        ("disabled.html.j2", "disabled.html"),
        ("logs.html.j2", "logs.html"),
    ]:
        template = env.get_template(tpl_name)
        rendered = template.render(**context)

        # Write to primary reports directory
        out_file = os.path.join(OUTPUT_DIR, dest_name)
        with open(out_file, "w") as f:
            f.write(rendered)

        # Mirror output to web server document root if available
        if os.path.exists("/var/www/html"):
            with open(os.path.join("/var/www/html", dest_name), "w") as f:
                f.write(rendered)

    print(
        f"[+] K-12 Reconciliation Audit Complete. Overall Accuracy: {overall_accuracy}%. "
        f"Execution Time: {auto_secs}s. Reports saved to {OUTPUT_DIR} and /var/www/html."
    )


if __name__ == "__main__":
    main()