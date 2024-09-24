import json
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
import schedule
import time
import threading

HOST = '127.0.0.1'
PORT = 8080  # Changed to 8080 so you don't need sudo privileges

rds_versions = []

def fetch_rds_versions():
    global rds_versions
    try:
        # Run the AWS CLI command
        result = subprocess.run([
            'aws', 'rds', 'describe-db-engine-versions',
            '--query', 'DBEngineVersions[].{Engine:Engine,EngineVersion:EngineVersion}',
            '--output', 'json'
        ], capture_output=True, text=True, check=True)

        # Parse the JSON output
        rds_versions = json.loads(result.stdout)
        print("RDS versions updated successfully")
    except Exception as e:
        print(f"Error fetching RDS versions: {str(e)}")

class RequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/aws_rds_version':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(rds_versions).encode())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'404 Not Found')

def run_server():
    server = HTTPServer((HOST, PORT), RequestHandler)
    print(f"Server running on http://{HOST}:{PORT}")
    server.serve_forever()

def update_versions():
    while True:
        schedule.run_pending()
        time.sleep(1)

if __name__ == '__main__':
    # Fetch versions immediately on startup
    fetch_rds_versions()

    # Schedule to fetch versions every day at midnight
    schedule.every().day.at("00:00").do(fetch_rds_versions)

    # Start the version update thread
    update_thread = threading.Thread(target=update_versions)
    update_thread.start()

    # Run the server
    run_server()
