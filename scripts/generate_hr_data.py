import psycopg2
import yaml
import random
from faker import Faker

fake = Faker()

# 1. Load database credentials from vault
with open("vars/vault.yml", "r") as f:
    vault = yaml.safe_load(f)

DB_HOST = vault.get("db_host", "localhost")
DB_NAME = vault.get("db_name", "hr_db")
DB_USER = vault.get("vault_db_user", "postgres")
DB_PASS = vault.get("vault_db_password", "secret")
DB_PORT = vault.get("db_port", 5432)

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS,
        port=DB_PORT
    )

def get_or_create_department(cursor):
    """
    80% chance to pick an existing active department (populates existing groups).
    20% chance to generate a brand-new department (forces pipeline to create a new AD group).
    """
    cursor.execute("SELECT DISTINCT department FROM employees WHERE department IS NOT NULL;")
    existing_depts = [row[0] for row in cursor.fetchall()]

    if existing_depts and random.random() > 0.20:
        return random.choice(existing_depts)
    else:
        # Auto-generate a multi-word department name like "Cloud Infrastructure" or "Strategic Operations"
        words = fake.bs().split()
        new_dept = f"{words[0].capitalize()} {words[1].capitalize()}" if len(words) >= 2 else fake.job().split()[0]
        return new_dept

def generate_new_hire(cursor):
    first_name = fake.first_name()
    last_name = fake.last_name()
    username = f"{first_name[0].lower()}{last_name.lower()}"
    email = f"{username}@apex.lab"
    
    department = get_or_create_department(cursor)
    title = fake.job()  # Auto-generates realistic job titles (e.g., "Systems Analyst", "DevOps Engineer")
    
    query = """
    INSERT INTO employees (first_name, last_name, username, department, title, email, status)
    VALUES (%s, %s, %s, %s, %s, %s, 'ACTIVE')
    ON CONFLICT (username) DO NOTHING;
    """
    cursor.execute(query, (first_name, last_name, username, department, title, email))
    print(f"[+] HIRED: {first_name} {last_name} ({username}) | Dept: '{department}' | Title: '{title}'")

def simulate_department_transfer(cursor):
    # Grab an active user
    cursor.execute("""
        SELECT username, department 
        FROM employees 
        WHERE status = 'ACTIVE' 
        ORDER BY RANDOM() LIMIT 1;
    """)
    user = cursor.fetchone()
    if user:
        username, current_dept = user
        # Force transfer into a brand-new or different department
        new_dept = get_or_create_department(cursor)
        while new_dept == current_dept:
            new_dept = get_or_create_department(cursor)
            
        cursor.execute("""
            UPDATE employees 
            SET department = %s 
            WHERE username = %s;
        """, (new_dept, username))
        print(f"[*] TRANSFERRED: {username} | From: '{current_dept}' -> To: '{new_dept}'")

def simulate_termination(cursor):
    cursor.execute("""
        SELECT username 
        FROM employees 
        WHERE status = 'ACTIVE' 
        ORDER BY RANDOM() LIMIT 1;
    """)
    user = cursor.fetchone()
    if user:
        username = user[0]
        cursor.execute("""
            UPDATE employees 
            SET status = 'TERMINATED' 
            WHERE username = %s;
        """, (username,))
        print(f"[-] TERMINATED: {username}")

if __name__ == "__main__":
    conn = get_db_connection()
    cursor = conn.cursor()
    
    print("--- Simulating HR Lifecycle Events ---")
    
    # Generate 3 new hires
    for _ in range(3):
        generate_new_hire(cursor)
        
    # Simulate 1 department transfer
    simulate_department_transfer(cursor)
    
    # Simulate 1 termination
    simulate_termination(cursor)
    
    conn.commit()
    cursor.close()
    conn.close()
    print("--- Database Update Complete ---")