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
DEPARTMENTS_FILE = os.path.join(SCRIPT_DIR, "departments.json")

def load_departments(filepath):
    """Loads department names from an external JSON file."""
    if not os.path.exists(filepath):
        print(f"[!] Error: Department configuration file not found at {filepath}")
        sys.exit(1)
        
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            departments = json.load(f)
            if not isinstance(departments, list) or not departments:
                raise ValueError("JSON content must be a non-empty list of strings.")
            return departments
    except Exception as e:
        print(f"[!] Error reading {filepath}: {e}")
        sys.exit(1)

# Dynamically load departments list
REAL_DEPARTMENTS = load_departments(DEPARTMENTS_FILE)

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
DB_USER = vault.get("vault_db_user") or vault.get("db_user", "hr_admin")
DB_PASS = vault.get("vault_db_password") or vault.get("db_password", "ApexPassword123!")
DB_PORT = vault.get("db_port", 5432)

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS,
        port=DB_PORT
    )

def get_random_department(current_dept=None):
    """
    Selects a department from REAL_DEPARTMENTS.
    If current_dept is provided, guarantees a different department is chosen for transfers.
    Enforces 50-character limit to comply with database column constraints.
    """
    available_depts = [d for d in REAL_DEPARTMENTS if d != current_dept]
    if not available_depts:
        available_depts = REAL_DEPARTMENTS
    chosen_dept = random.choice(available_depts)
    return chosen_dept[:50]

def generate_new_hire(cursor, existing_usernames):
    """
    Generates a unique new hire.
    Appends numeric suffixes if username collisions occur to guarantee successful DB insertion.
    """
    while True:
        first_name = fake.first_name()[:50]
        last_name = fake.last_name()[:50]
        
        # Base username construction
        clean_first = first_name[0].lower().replace(" ", "").replace("'", "")
        clean_last = last_name.lower().replace(" ", "").replace("'", "")
        base_username = f"{clean_first}{clean_last}"[:45]
        
        username = base_username
        counter = 1
        
        # Check against database and current run cache for collisions
        while True:
            cursor.execute("SELECT 1 FROM employees WHERE username = %s;", (username,))
            if not cursor.fetchone() and username not in existing_usernames:
                break
            username = f"{base_username}{counter}"[:50]
            counter += 1
            
        email = f"{username}@apex.lab"[:50]
        department = get_random_department()
        
        query = """
        INSERT INTO employees (first_name, last_name, username, department, email, status)
        VALUES (%s, %s, %s, %s, %s, 'ACTIVE')
        ON CONFLICT (username) DO NOTHING;
        """
        cursor.execute(query, (first_name, last_name, username, department, email))
        
        if cursor.rowcount > 0:
            print(f"[+] HIRED: {first_name} {last_name} ({username}) | Dept: '{department}'")
            existing_usernames.add(username)
            return username

def simulate_department_transfer(cursor, exclude_usernames=None):
    exclude_usernames = exclude_usernames or set()
    
    if exclude_usernames:
        query = """
            SELECT username, department 
            FROM employees 
            WHERE status = 'ACTIVE' AND username NOT IN %s
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query, (tuple(exclude_usernames),))
    else:
        query = """
            SELECT username, department 
            FROM employees 
            WHERE status = 'ACTIVE'
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query)

    user = cursor.fetchone()
    if user:
        username, current_dept = user
        new_dept = get_random_department(current_dept=current_dept)
            
        cursor.execute("""
            UPDATE employees 
            SET department = %s 
            WHERE username = %s;
        """, (new_dept, username))
        print(f"[*] TRANSFERRED: {username} | From: '{current_dept}' -> To: '{new_dept}'")
        return username
    return None

def simulate_termination(cursor, exclude_usernames=None):
    exclude_usernames = exclude_usernames or set()
    
    if exclude_usernames:
        query = """
            SELECT username 
            FROM employees 
            WHERE status = 'ACTIVE' AND username NOT IN %s
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query, (tuple(exclude_usernames),))
    else:
        query = """
            SELECT username 
            FROM employees 
            WHERE status = 'ACTIVE'
            ORDER BY RANDOM() LIMIT 1;
        """
        cursor.execute(query)

    user = cursor.fetchone()
    if user:
        username = user[0]
        cursor.execute("""
            UPDATE employees 
            SET status = 'TERMINATED',
                terminated_at = NOW() 
            WHERE username = %s;
        """, (username,))
        print(f"[-] TERMINATED: {username}")
        return username
    return None

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="HR Synthetic Data Generator")
    parser.add_argument("--hires", type=int, default=3, help="Number of new hires to generate")
    parser.add_argument("--transfers", type=int, default=1, help="Number of department transfers to generate")
    parser.add_argument("--terms", type=int, default=1, help="Number of terminations to generate")
    args = parser.parse_args()

    conn = get_db_connection()
    cursor = conn.cursor()
    
    print("--- Simulating HR Lifecycle Events ---")
    
    processed_this_run = set()
    
    # 1. Generate Hires
    for _ in range(args.hires):
        new_user = generate_new_hire(cursor, processed_this_run)
        if new_user:
            processed_this_run.add(new_user)
        
    # 2. Simulate Transfers
    for _ in range(args.transfers):
        transferred_user = simulate_department_transfer(cursor, exclude_usernames=processed_this_run)
        if transferred_user:
            processed_this_run.add(transferred_user)
    
    # 3. Simulate Terminations
    for _ in range(args.terms):
        terminated_user = simulate_termination(cursor, exclude_usernames=processed_this_run)
        if terminated_user:
            processed_this_run.add(terminated_user)
    
    conn.commit()
    cursor.close()
    conn.close()
    print("--- Database Update Complete ---")