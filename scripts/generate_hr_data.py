#!/usr/bin/env python3
import psycopg2
import yaml
import random
import argparse
import json
import os
import sys
import shutil
import subprocess
from faker import Faker

fake = Faker()

# Absolute path resolution relative to script location
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# K-12 Campus & Identity Configurations
SCHOOL_CONFIG = [
    {"name": "Oakridge Elementary", "type": "STUDENT", "grades": ["00", "01", "02", "03", "04", "05"]},
    {"name": "Pinecrest Elementary", "type": "STUDENT", "grades": ["00", "01", "02", "03", "04", "05"]},
    {"name": "Lakeside Middle School", "type": "STUDENT", "grades": ["06", "07", "08"]},
    {"name": "Apex High School", "type": "STUDENT", "grades": ["09", "10", "11", "12"]},
]

STAFF_CONFIG = [
    {"user_type": "FACULTY", "dept": "Instructional Staff"},
    {"user_type": "ADMIN", "dept": "Administration"},
    {"user_type": "SUPPORT", "dept": "IT & Operational Support"},
]

SCHOOL_NAMES = [s["name"] for s in SCHOOL_CONFIG]

# Resolve Vault paths
vault_path = "vars/vault.yml"
if not os.path.exists(vault_path):
    vault_path = os.path.join(SCRIPT_DIR, "..", "vars", "vault.yml")

vault_pass_path = os.path.join(os.path.dirname(vault_path), ".vault_pass")

def load_vault_config(v_path, p_path):
    """Decrypts Ansible Vault file in memory to retrieve connection secrets."""
    vault_bin = shutil.which("ansible-vault") or "/usr/bin/ansible-vault"
    
    if os.path.exists(v_path) and os.path.exists(p_path) and os.path.exists(vault_bin):
        try:
            cmd = [
                vault_bin, "view",
                v_path,
                "--vault-password-file", p_path
            ]
            env = os.environ.copy()
            env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:" + env.get("PATH", "")
            
            res = subprocess.run(cmd, capture_output=True, text=True, check=True, env=env)
            parsed = yaml.safe_load(res.stdout)
            if isinstance(parsed, dict):
                return parsed
        except Exception as e:
            print(f"[!] Warning: Could not decrypt vault via ansible-vault: {e}")

    # Fallback to plain YAML read if unencrypted
    try:
        with open(v_path, "r") as f:
            parsed = yaml.safe_load(f)
            if isinstance(parsed, dict):
                return parsed
    except Exception as e:
        print(f"[!] Error reading {v_path}: {e}")

    return {}

# Load decrypted vault parameters
vault = load_vault_config(vault_path, vault_pass_path)

DB_HOST = vault.get("db_host", "10.2.8.106")
DB_NAME = vault.get("db_name", "hr_db")
DB_USER = vault.get("vault_db_user") or vault.get("db_user", "postgres")
DB_PASS = vault.get("vault_db_password") or vault.get("db_password", "MySecretAnsibleToken123!")
DB_PORT = vault.get("db_port", 5432)

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS,
        port=DB_PORT
    )

def generate_new_hire(cursor, existing_usernames, verbose=True):
    """
    Generates a unique K-12 identity (80% Student, 20% Staff).
    Ensures unique usernames and valid school/grade mappings.
    """
    is_student = random.random() < 0.8
    
    while True:
        first_name = fake.first_name()[:50]
        last_name = fake.last_name()[:50]
        
        clean_first = first_name[0].lower().replace(" ", "").replace("'", "")
        clean_last = last_name.lower().replace(" ", "").replace("'", "")
        
        if is_student:
            base_username = f"{clean_first}{clean_last}{random.randint(100, 999)}"[:45]
        else:
            base_username = f"{clean_first}{clean_last}"[:45]
            
        username = base_username
        counter = 1
        
        while True:
            cursor.execute("SELECT 1 FROM employees WHERE username = %s;", (username,))
            if not cursor.fetchone() and username not in existing_usernames:
                break
            username = f"{base_username}{counter}"[:50]
            counter += 1
            
        email = f"{username}@apex.lab"[:50]
        
        if is_student:
            user_type = "STUDENT"
            school_info = random.choice(SCHOOL_CONFIG)
            school = school_info["name"]
            grade_level = random.choice(school_info["grades"])
            department = f"Grade {grade_level}"
        else:
            staff_info = random.choice(STAFF_CONFIG)
            user_type = staff_info["user_type"]
            school = random.choice(SCHOOL_NAMES)
            grade_level = "N/A"
            department = staff_info["dept"]
        
        query = """
        INSERT INTO employees (first_name, last_name, username, user_type, school, grade_level, department, email, status, legal_hold)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'ACTIVE', False)
        ON CONFLICT (username) DO NOTHING;
        """
        cursor.execute(query, (first_name, last_name, username, user_type, school, grade_level, department, email))
        
        if cursor.rowcount > 0:
            if verbose:
                if is_student:
                    print(f"[+] ENROLLED: {first_name} {last_name} ({username}) | Type: STUDENT | Campus: '{school}' | Cohort: '{department}'")
                else:
                    print(f"[+] HIRED: {first_name} {last_name} ({username}) | Type: {user_type} | Campus: '{school}' | Dept: '{department}'")
            existing_usernames.add(username)
            return username

def simulate_department_transfer(cursor, exclude_usernames=None):
    """
    Simulates grade promotion/graduation for students or school reassignment for staff.
    """
    exclude_usernames = exclude_usernames or set()
    
    if exclude_usernames:
        query = """
            SELECT username, user_type, school, grade_level, department 
            FROM employees 
            WHERE status = 'ACTIVE' AND username NOT IN %s
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query, (tuple(exclude_usernames),))
    else:
        query = """
            SELECT username, user_type, school, grade_level, department 
            FROM employees 
            WHERE status = 'ACTIVE'
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query)

    user = cursor.fetchone()
    if user:
        username, user_type, current_school, current_grade, current_dept = user
        
        if user_type == "STUDENT":
            if current_grade == "12" or current_grade == "GRAD":
                # Senior Graduation Event -> Shift to Graduates OU & GRP_Graduates
                new_grade = "GRAD"
                new_school = "Graduates"
                new_dept = "Alumni"
                
                cursor.execute("""
                    UPDATE employees 
                    SET school = %s, grade_level = %s, department = %s 
                    WHERE username = %s;
                """, (new_school, new_grade, new_dept, username))
                print(f"[*] GRADUATED: {username} | Apex High School (Grade 12) -> Graduates OU")
            else:
                # Standard Grade promotion logic
                grade_int = int(current_grade) if current_grade.isdigit() else 0
                new_grade_int = grade_int + 1
                
                if new_grade_int > 12:
                    new_grade = "GRAD"
                    new_school = "Graduates"
                    new_dept = "Alumni"
                    print(f"[*] GRADUATED: {username} | {current_school} (Grade {current_grade}) -> Graduates OU")
                else:
                    new_grade = f"{new_grade_int:02d}"
                    if new_grade_int <= 5:
                        new_school = current_school if "Elementary" in current_school else random.choice(["Oakridge Elementary", "Pinecrest Elementary"])
                    elif new_grade_int <= 8:
                        new_school = "Lakeside Middle School"
                    else:
                        new_school = "Apex High School"
                    new_dept = f"Grade {new_grade}"
                    
                    print(f"[*] PROMOTED: {username} | Cohort: '{current_school} ({current_dept})' -> '{new_school} ({new_dept})'")

                cursor.execute("""
                    UPDATE employees 
                    SET school = %s, grade_level = %s, department = %s 
                    WHERE username = %s;
                """, (new_school, new_grade, new_dept, username))
        else:
            # Staff school transfer logic
            available_schools = [s for s in SCHOOL_NAMES if s != current_school]
            new_school = random.choice(available_schools)
            
            cursor.execute("""
                UPDATE employees 
                SET school = %s 
                WHERE username = %s;
            """, (new_school, username))
            print(f"[*] TRANSFERRED: {username} | Campus: '{current_school}' -> '{new_school}' (Staff Reassignment)")
            
        return username
    return None

def simulate_termination(cursor, exclude_usernames=None):
    """
    Simulates student withdrawal or staff termination.
    """
    exclude_usernames = exclude_usernames or set()
    
    if exclude_usernames:
        query = """
            SELECT username, user_type, school 
            FROM employees 
            WHERE status = 'ACTIVE' AND username NOT IN %s
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query, (tuple(exclude_usernames),))
    else:
        query = """
            SELECT username, user_type, school 
            FROM employees 
            WHERE status = 'ACTIVE'
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query)

    user = cursor.fetchone()
    if user:
        username, user_type, school = user
        cursor.execute("""
            UPDATE employees 
            SET status = 'TERMINATED',
                terminated_at = NOW() 
            WHERE username = %s;
        """, (username,))
        if user_type == "STUDENT":
            print(f"[-] WITHDRAWN: {username} | Type: STUDENT | Campus: '{school}' | 30-Day Retention Grace Period Initiated")
        else:
            print(f"[-] SEPARATED: {username} | Type: {user_type} | Campus: '{school}' | Account Disabled")
        return username
    return None

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="K-12 SIS Identity Event Generator")
    parser.add_argument("--count", type=int, default=None, help="Bulk initial seeding count (overrides hires/transfers/terms)")
    parser.add_argument("--hires", type=int, default=3, help="Number of new enrollments/staff hires to generate")
    parser.add_argument("--transfers", type=int, default=1, help="Number of grade/school transitions to generate")
    parser.add_argument("--terms", type=int, default=1, help="Number of withdrawals/terminations to generate")
    args = parser.parse_args()

    conn = get_db_connection()
    cursor = conn.cursor()
    
    print("--- Simulating SIS (Student Information System) Real-Time Data Stream ---")
    
    processed_this_run = set()
    
    if args.count:
        print(f"[*] Bulk seeding SIS database with {args.count} synthetic K-12 student and staff identities...")
        for i in range(args.count):
            verbose_log = (args.count <= 20) or ((i + 1) % 100 == 0)
            new_user = generate_new_hire(cursor, processed_this_run, verbose=verbose_log)
            if verbose_log and args.count > 20:
                print(f"    [+] Seeded {i + 1}/{args.count} identities...")
    else:
        # 1. Generate Enrollments / Hires
        for _ in range(args.hires):
            new_user = generate_new_hire(cursor, processed_this_run, verbose=True)
            if new_user:
                processed_this_run.add(new_user)
            
        # 2. Simulate Transitions / Graduations
        for _ in range(args.transfers):
            transferred_user = simulate_department_transfer(cursor, exclude_usernames=processed_this_run)
            if transferred_user:
                processed_this_run.add(transferred_user)
        
        # 3. Simulate Terminations / Withdrawals
        for _ in range(args.terms):
            terminated_user = simulate_termination(cursor, exclude_usernames=processed_this_run)
            if terminated_user:
                processed_this_run.add(terminated_user)
    
    conn.commit()
    cursor.close()
    conn.close()
    print("--- Database Update Complete ---")