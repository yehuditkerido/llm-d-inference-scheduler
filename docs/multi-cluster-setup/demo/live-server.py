#!/usr/bin/env python3
"""
Live Multi-Cluster Dashboard Server
Fetches metrics from EPPs and serves a real-time web dashboard.
No external dependencies - uses only Python standard library.
"""

import http.server
import json
import subprocess
import threading
import time
from urllib.request import urlopen, Request
from urllib.error import URLError
import ssl

# EPP Endpoints
SPOKE1_EPP = "https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com/metrics"
SPOKE2_EPP = "https://epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com/metrics"
HUB_EPP = "https://epp-metrics-llm-d-system.apps.aigrid-hub.aigriddev.sysdeseng.com/metrics"

# Global metrics cache
metrics_cache = {
    "spoke1": {"queue": 0, "kv": 0, "running": 0, "ready": 0},
    "spoke2": {"queue": 0, "kv": 0, "running": 0, "ready": 0},
    "hub": {"ready": 0},
    "last_update": ""
}

def fetch_metrics(url):
    """Fetch metrics from an EPP endpoint."""
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = Request(url, headers={"User-Agent": "Dashboard/1.0"})
        with urlopen(req, timeout=5, context=ctx) as response:
            return response.read().decode("utf-8")
    except Exception as e:
        return None

def parse_metric(text, metric_name):
    """Extract a metric value from Prometheus text format."""
    if not text:
        return 0
    for line in text.split("\n"):
        if line.startswith(f"{metric_name}{{"):
            try:
                return float(line.split("} ")[1])
            except:
                pass
    return 0

def update_metrics():
    """Background thread to update metrics cache."""
    global metrics_cache
    while True:
        try:
            # Fetch Spoke1
            s1 = fetch_metrics(SPOKE1_EPP)
            metrics_cache["spoke1"] = {
                "queue": parse_metric(s1, "llm_d_epp_average_queue_size"),
                "kv": parse_metric(s1, "llm_d_epp_average_kv_cache_utilization"),
                "running": parse_metric(s1, "llm_d_epp_average_running_requests"),
                "ready": int(parse_metric(s1, "llm_d_epp_ready_endpoints")),
            }
            
            # Fetch Spoke2
            s2 = fetch_metrics(SPOKE2_EPP)
            metrics_cache["spoke2"] = {
                "queue": parse_metric(s2, "llm_d_epp_average_queue_size"),
                "kv": parse_metric(s2, "llm_d_epp_average_kv_cache_utilization"),
                "running": parse_metric(s2, "llm_d_epp_average_running_requests"),
                "ready": int(parse_metric(s2, "llm_d_epp_ready_endpoints")),
            }
            
            # Fetch Hub
            hub = fetch_metrics(HUB_EPP)
            metrics_cache["hub"] = {
                "ready": int(parse_metric(hub, "llm_d_epp_ready_endpoints")),
            }
            
            metrics_cache["last_update"] = time.strftime("%H:%M:%S")
        except Exception as e:
            print(f"Error updating metrics: {e}")
        
        time.sleep(2)

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Live Multi-Cluster Dashboard</title>
    <style>
        :root {
            --bg-dark: #0d1117;
            --bg-card: #161b22;
            --border: #30363d;
            --text: #e6edf3;
            --text-dim: #8b949e;
            --green: #3fb950;
            --cyan: #58a6ff;
            --orange: #d29922;
            --red: #f85149;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
            background: var(--bg-dark);
            color: var(--text);
            padding: 20px;
            min-height: 100vh;
        }
        .header {
            text-align: center;
            margin-bottom: 30px;
        }
        .header h1 {
            font-size: 2em;
            background: linear-gradient(90deg, var(--cyan), var(--green));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .header .status {
            margin-top: 10px;
            color: var(--text-dim);
        }
        .status .dot {
            display: inline-block;
            width: 8px;
            height: 8px;
            border-radius: 50%;
            margin-right: 5px;
            animation: pulse 2s infinite;
        }
        .status .dot.green { background: var(--green); }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.4; }
        }
        .grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            max-width: 1200px;
            margin: 0 auto;
        }
        .card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 20px;
        }
        .card.full { grid-column: 1 / -1; }
        .card-title {
            font-size: 1.2em;
            font-weight: 600;
            margin-bottom: 15px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .card-title.spoke1 { color: var(--green); }
        .card-title.spoke2 { color: var(--cyan); }
        .card-title.routing { color: var(--orange); }
        .badge {
            font-size: 0.7em;
            background: var(--border);
            padding: 4px 10px;
            border-radius: 20px;
            color: var(--text-dim);
        }
        .metrics {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
        }
        .metric {
            background: rgba(0,0,0,0.3);
            padding: 15px;
            border-radius: 8px;
        }
        .metric-label {
            font-size: 0.85em;
            color: var(--text-dim);
            margin-bottom: 5px;
        }
        .metric-value {
            font-size: 1.8em;
            font-weight: 700;
        }
        .metric-value.green { color: var(--green); }
        .metric-value.cyan { color: var(--cyan); }
        .routing-box {
            text-align: center;
            padding: 30px;
        }
        .routing-label {
            color: var(--text-dim);
            margin-bottom: 10px;
        }
        .routing-target {
            font-size: 2.5em;
            font-weight: 700;
            margin-bottom: 10px;
        }
        .routing-target.green { color: var(--green); }
        .routing-target.cyan { color: var(--cyan); }
        .routing-target.orange { color: var(--orange); }
        .scores {
            display: flex;
            justify-content: center;
            gap: 50px;
            margin-top: 20px;
        }
        .score-item {
            text-align: center;
        }
        .score-bar {
            width: 120px;
            height: 8px;
            background: var(--border);
            border-radius: 4px;
            margin: 10px 0;
            overflow: hidden;
        }
        .score-fill {
            height: 100%;
            border-radius: 4px;
            transition: width 0.5s ease;
        }
        .score-fill.green { background: var(--green); }
        .score-fill.cyan { background: var(--cyan); }
        .log-box {
            background: rgba(0,0,0,0.3);
            border-radius: 8px;
            padding: 15px;
            font-family: monospace;
            font-size: 0.85em;
            max-height: 200px;
            overflow-y: auto;
        }
        .log-entry {
            padding: 3px 0;
            border-bottom: 1px solid var(--border);
        }
        .log-entry:last-child { border-bottom: none; }
        .log-time { color: var(--text-dim); }
        .log-event { margin-left: 10px; }
        .log-event.load { color: var(--orange); }
        .log-event.route { color: var(--green); }
    </style>
</head>
<body>
    <div class="header">
        <h1>Multi-Cluster Hub-and-Spoke Dashboard</h1>
        <div class="status">
            <span class="dot green"></span>
            Live - Last update: <span id="lastUpdate">--:--:--</span>
            | Hub sees <span id="hubReady">0</span> Spoke clusters
        </div>
        <div class="status" style="margin-top: 8px; font-family: monospace; font-size: 0.9em;">
            Hub Gateway: <a href="https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com" target="_blank" style="color: var(--cyan);">https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com</a>
        </div>
    </div>
    
    <div class="grid">
        <div class="card">
            <div class="card-title spoke1">
                Spoke 1 (aigrid-tenant1)
                <span class="badge">us-east-2</span>
            </div>
            <div class="metrics">
                <div class="metric">
                    <div class="metric-label">Ready Pods</div>
                    <div class="metric-value green" id="s1-ready">0</div>
                </div>
                <div class="metric">
                    <div class="metric-label">Avg Queue</div>
                    <div class="metric-value" id="s1-queue">0</div>
                </div>
                <div class="metric">
                    <div class="metric-label">Avg Running</div>
                    <div class="metric-value" id="s1-running">0</div>
                </div>
                <div class="metric">
                    <div class="metric-label">KV Cache %</div>
                    <div class="metric-value" id="s1-kv">0%</div>
                </div>
            </div>
        </div>
        
        <div class="card">
            <div class="card-title spoke2">
                Spoke 2 (aigrid-tenant2)
                <span class="badge">us-west-2</span>
            </div>
            <div class="metrics">
                <div class="metric">
                    <div class="metric-label">Ready Pods</div>
                    <div class="metric-value cyan" id="s2-ready">0</div>
                </div>
                <div class="metric">
                    <div class="metric-label">Avg Queue</div>
                    <div class="metric-value" id="s2-queue">0</div>
                </div>
                <div class="metric">
                    <div class="metric-label">Avg Running</div>
                    <div class="metric-value" id="s2-running">0</div>
                </div>
                <div class="metric">
                    <div class="metric-label">KV Cache %</div>
                    <div class="metric-value" id="s2-kv">0%</div>
                </div>
            </div>
        </div>
        
        <div class="card full">
            <div class="card-title routing">Routing Decision</div>
            <div class="routing-box">
                <div class="routing-label">Next inference request would route to:</div>
                <div class="routing-target" id="routing-target">Calculating...</div>
                <div id="routing-reason" style="color: var(--text-dim);">Based on load metrics</div>
                
                <div class="scores">
                    <div class="score-item">
                        <div>Spoke 1 Score</div>
                        <div class="score-bar"><div class="score-fill green" id="s1-bar" style="width: 50%"></div></div>
                        <div id="s1-score">0.00</div>
                    </div>
                    <div class="score-item">
                        <div>Spoke 2 Score</div>
                        <div class="score-bar"><div class="score-fill cyan" id="s2-bar" style="width: 50%"></div></div>
                        <div id="s2-score">0.00</div>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="card full">
            <div class="card-title">Event Log</div>
            <div class="log-box" id="log-box"></div>
        </div>
    </div>

    <script>
        const logs = [];
        let lastS1Running = 0;
        let lastS2Running = 0;
        let lastTarget = "";
        
        function addLog(event, type) {
            const time = new Date().toLocaleTimeString();
            logs.unshift({time, event, type});
            if (logs.length > 20) logs.pop();
            
            const box = document.getElementById('log-box');
            box.innerHTML = logs.map(l => 
                `<div class="log-entry"><span class="log-time">${l.time}</span><span class="log-event ${l.type}">${l.event}</span></div>`
            ).join('');
        }
        
        // Demo scoring: absolute reference (produces fractional scores for visualization)
        // Preserves correctness: same winner as EPP (lower load = higher score)
        function calculateScores(s1, s2) {
            // Queue: lower is better. Score 1.0 at queue=0, score 0.0 at queue>=10
            const s1QScore = Math.max(0, 1 - s1.queue / 10);
            const s2QScore = Math.max(0, 1 - s2.queue / 10);
            
            // Running: lower is better. Score 1.0 at running=0, score 0.0 at running>=30
            const s1RunScore = Math.max(0, 1 - s1.running / 30);
            const s2RunScore = Math.max(0, 1 - s2.running / 30);
            
            // KV cache: lower is better. Amplify by 5x for visibility (0.1 -> 0.5 impact)
            const s1KVScore = Math.max(0, 1 - s1.kv * 5);
            const s2KVScore = Math.max(0, 1 - s2.kv * 5);
            
            // Final weighted score: queue*1 + running*2 + kv*1 (0-4 range)
            return {
                s1: s1QScore * 1 + s1RunScore * 2 + s1KVScore * 1,
                s2: s2QScore * 1 + s2RunScore * 2 + s2KVScore * 1
            };
        }
        
        function updateDashboard(data) {
            const s1 = data.spoke1;
            const s2 = data.spoke2;
            
            document.getElementById('lastUpdate').textContent = data.last_update;
            document.getElementById('hubReady').textContent = data.hub.ready;
            
            document.getElementById('s1-ready').textContent = s1.ready;
            document.getElementById('s1-queue').textContent = s1.queue.toFixed(1);
            document.getElementById('s1-running').textContent = s1.running.toFixed(1);
            document.getElementById('s1-kv').textContent = (s1.kv * 100).toFixed(1) + '%';
            
            document.getElementById('s2-ready').textContent = s2.ready;
            document.getElementById('s2-queue').textContent = s2.queue.toFixed(1);
            document.getElementById('s2-running').textContent = s2.running.toFixed(1);
            document.getElementById('s2-kv').textContent = (s2.kv * 100).toFixed(1) + '%';
            
            // Log significant changes
            if (Math.abs(s1.running - lastS1Running) > 5) {
                addLog(`Spoke1 running: ${lastS1Running.toFixed(0)} -> ${s1.running.toFixed(0)}`, 'load');
                lastS1Running = s1.running;
            }
            if (Math.abs(s2.running - lastS2Running) > 5) {
                addLog(`Spoke2 running: ${lastS2Running.toFixed(0)} -> ${s2.running.toFixed(0)}`, 'load');
                lastS2Running = s2.running;
            }
            
            // Calculate scores (EPP-style: normalized, weighted)
            const scores = calculateScores(s1, s2);
            const s1Score = scores.s1;
            const s2Score = scores.s2;
            
            document.getElementById('s1-score').textContent = s1Score.toFixed(2);
            document.getElementById('s2-score').textContent = s2Score.toFixed(2);
            document.getElementById('s1-bar').style.width = (s1Score / 4 * 100) + '%';
            document.getElementById('s2-bar').style.width = (s2Score / 4 * 100) + '%';
            
            // Routing decision
            const target = document.getElementById('routing-target');
            const reason = document.getElementById('routing-reason');
            let newTarget = "";
            
            if (s1Score > s2Score + 0.1) {
                target.textContent = 'Spoke 1 (us-east-2)';
                target.className = 'routing-target green';
                reason.textContent = `Score ${s1Score.toFixed(2)} > ${s2Score.toFixed(2)}: Lower load on Spoke 1`;
                newTarget = "Spoke1";
            } else if (s2Score > s1Score + 0.1) {
                target.textContent = 'Spoke 2 (us-west-2)';
                target.className = 'routing-target cyan';
                reason.textContent = `Score ${s2Score.toFixed(2)} > ${s1Score.toFixed(2)}: Lower load on Spoke 2`;
                newTarget = "Spoke2";
            } else {
                target.textContent = 'Either (Balanced)';
                target.className = 'routing-target orange';
                reason.textContent = 'Scores are similar - round-robin selection';
                newTarget = "Balanced";
            }
            
            if (newTarget !== lastTarget && lastTarget !== "") {
                addLog(`Routing changed: ${lastTarget} -> ${newTarget}`, 'route');
            }
            lastTarget = newTarget;
        }
        
        function fetchMetrics() {
            fetch('/metrics')
                .then(r => r.json())
                .then(updateDashboard)
                .catch(e => console.error('Fetch error:', e));
        }
        
        // Initial fetch and start polling
        addLog('Dashboard started', 'route');
        fetchMetrics();
        setInterval(fetchMetrics, 2000);
    </script>
</body>
</html>
"""

class DashboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging
    
    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(metrics_cache).encode())
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(DASHBOARD_HTML.encode())

def main():
    port = 8080
    
    # Start background metrics updater
    updater = threading.Thread(target=update_metrics, daemon=True)
    updater.start()
    
    print(f"""
╔══════════════════════════════════════════════════════════════════╗
║  Multi-Cluster Live Dashboard Server                             ║
╠══════════════════════════════════════════════════════════════════╣
║  Dashboard URL: http://localhost:{port}                           ║
║  Metrics API:   http://localhost:{port}/metrics                   ║
║                                                                  ║
║  Press Ctrl+C to stop                                            ║
╚══════════════════════════════════════════════════════════════════╝
""")
    
    class ReusableHTTPServer(http.server.HTTPServer):
        allow_reuse_address = True
    
    server = ReusableHTTPServer(("", port), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()

if __name__ == "__main__":
    main()
