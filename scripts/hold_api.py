#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from jinja2 import Environment, FileSystemLoader
import psycopg2
from psycopg2.extras import RealDictCursor
import yaml

VAULT_BIN = shutil.which("ansible-vault") or "/usr/bin/ansible-vault"
VAULT_FILE = "/root/ansible/vars/vault.yml"
VAULT_PASS_FILE = "/root/ansible/vars/.vault_pass"

def get_vault_credentials():
    """Decrypt vault.yml in memory and extract database connection settings."""
    cmd = [
        VAULT_BIN, "view",
        VAULT_FILE,
        "--vault-password-file", VAULT_PASS_FILE
    ]
    env = os.environ.copy()
    env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:" + env.get("PATH", "")

    result = subprocess.run(cmd, capture_output=True, text=True, check=True, env=env)
    vault_data = yaml.safe_load(result.stdout)

    db_host = vault_data.get('db_host', '10.2.8.106')
    db_port = vault_data.get('db_port', 5432)
    db_name = vault_data.get('db_name', 'hr_db')
    db_user = vault_data.get('vault_db_user') or vault_data.get('db_user')
    db_pass = vault_data.get('vault_db_password') or vault_data.get('db_password')

    if not db_user or not db_pass:
        raise ValueError("Could not find 'vault_db_user' or 'vault_db_password' in decrypted vault.yml")

    return db_host, db_port, db_name, db_user, db_pass

class HoldHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/api/hold':
            try:
                content_length = int(self.headers.get('Content-Length', 0))
                post_data = self.rfile.read(content_length)
                data = json.loads(post_data.decode('utf-8'))
                
                username = data.get('username')
                hold_state = True if data.get('hold_state') is True else False

                if not username:
                    self._send_response(400, {"error": "Missing username"})
                    return

                # 1. Dynamically read DB credentials from vault.yml
                db_host, db_port, db_name, db_user, db_pass = get_vault_credentials()

                # 2. Update PostgreSQL directly
                conn = psycopg2.connect(
                    host=db_host, port=db_port, dbname=db_name,
                    user=db_user, password=db_pass
                )
                cur = conn.cursor(cursor_factory=RealDictCursor)
                
                cur.execute(
                    "UPDATE employees SET legal_hold = %s WHERE username = %s;",
                    (hold_state, username)
                )
                conn.commit()

                # 3. Query updated inactive users
                cur.execute("""
                    SELECT username, first_name, last_name, email, department, 
                           terminated_at::text, legal_hold
                    FROM employees
                    WHERE status = 'TERMINATED';
                """)
                inactive_users = cur.fetchall()
                cur.close()
                conn.close()

                # 4. Render Jinja2 template (<10ms)
                env = Environment(loader=FileSystemLoader('/root/ansible/templates'))
                template = env.get_template('disabled.html.j2')
                
                now = datetime.datetime.now()
                mock_facts = {
                    'ansible_facts': {
                        'date_time': {
                            'date': now.strftime('%Y-%m-%d'),
                            'hour': now.strftime('%H'),
                            'minute': now.strftime('%M'),
                            'second': now.strftime('%S'),
                            'tz': 'EDT'
                        }
                    }
                }

                rendered_html = template.render(
                    dynamic_inactive_users=inactive_users,
                    **mock_facts
                )

                with open('/var/www/html/disabled.html', 'w') as f:
                    f.write(rendered_html)

                print(f"[SUCCESS] Updated '{username}' legal_hold={hold_state}", flush=True)
                self._send_response(200, {"status": "success", "user": username, "legal_hold": hold_state})

            except Exception as e:
                print(f"[ERROR] API execution failed: {e}", flush=True)
                self._send_response(500, {"error": str(e)})
        else:
            self._send_response(404, {"error": "Not Found"})

    def _send_response(self, code, payload):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode('utf-8'))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 5000), HoldHandler)
    print("Legal Hold API listener active on port 5000...", flush=True)
    server.serve_forever()