"""
Ansible AI Agent — FastAPI Backend
Exposes REST + WebSocket endpoints for the dashboard.
"""

import asyncio, json, os, re, time
from pathlib import Path
from typing import Any, Optional
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, field_validator
import httpx
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

# Rate limiter setup
limiter = Limiter(key_func=get_remote_address)
app = FastAPI(title="Ansible AI Agent", version="1.0.0")
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Shared HTTP client for connection pooling
http_client: Optional[httpx.AsyncClient] = None

# ── Pydantic models ──────────────────────────────────────────────────────────

class PlaybookRequest(BaseModel):
    playbook: str          # path relative to ansible/playbooks/
    limit: str = "all"     # host pattern
    extra_vars: dict = {}
    
    @field_validator('playbook')
    @classmethod
    def validate_playbook(cls, v: str) -> str:
        # Prevent path traversal
        if '..' in v or v.startswith('/') or not v.endswith('.yml'):
            raise ValueError('Invalid playbook name')
        # Only allow alphanumeric, dash, underscore, dot
        if not re.match(r'^[a-zA-Z0-9_.-]+\.yml$', v):
            raise ValueError('Playbook name contains invalid characters')
        return v
    
    @field_validator('limit')
    @classmethod
    def validate_limit(cls, v: str) -> str:
        # Sanitize host pattern - allow only safe characters
        if not re.match(r'^[a-zA-Z0-9_.,*:-]+$', v):
            raise ValueError('Invalid host pattern')
        return v

class AICommandRequest(BaseModel):
    prompt: str
    context: dict = {}
    
    @field_validator('prompt')
    @classmethod
    def validate_prompt(cls, v: str) -> str:
        if len(v) > 500:
            raise ValueError('Prompt too long (max 500 chars)')
        return v

class AdHocRequest(BaseModel):
    module: str
    args: str = ""
    limit: str = "all"
    
    @field_validator('module')
    @classmethod
    def validate_module(cls, v: str) -> str:
        # Whitelist common safe modules
        allowed = {'ping', 'shell', 'command', 'copy', 'file', 'service', 'package', 'user', 'setup', 'debug'}
        if v not in allowed:
            raise ValueError(f'Module not allowed. Allowed: {allowed}')
        return v
    
    @field_validator('limit')
    @classmethod
    def validate_limit(cls, v: str) -> str:
        if not re.match(r'^[a-zA-Z0-9_.,*:-]+$', v):
            raise ValueError('Invalid host pattern')
        return v

# ── WebSocket connection manager ─────────────────────────────────────────────

class ConnectionManager:
    def __init__(self):
        self.active: list[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)

    def disconnect(self, ws: WebSocket):
        self.active.remove(ws)

    async def broadcast(self, data: dict):
        dead = []
        for ws in self.active:
            try:
                await ws.send_json(data)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.active.remove(ws)

manager = ConnectionManager()

# ── Configuration ────────────────────────────────────────────────────────────

ANSIBLE_DIR = os.environ.get("ANSIBLE_DIR", "/ansible")
INVENTORY   = os.environ.get("ANSIBLE_INVENTORY", f"{ANSIBLE_DIR}/inventory/hosts.ini")
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "5"))
SCRAPE_TIMEOUT = float(os.environ.get("SCRAPE_TIMEOUT", "3.0"))
PLAYBOOK_TIMEOUT = int(os.environ.get("PLAYBOOK_TIMEOUT", "300"))
ADHOC_TIMEOUT = int(os.environ.get("ADHOC_TIMEOUT", "60"))
AI_TIMEOUT = float(os.environ.get("AI_TIMEOUT", "30.0"))

# Inventory cache
inventory_cache: list[dict] = []
inventory_mtime: float = 0.0

# ── Metrics collector ────────────────────────────────────────────────────────

def _parse_node_exporter(raw: str) -> dict:
    """Parse only needed metrics from node_exporter text format."""
    metrics = {}
    # Regex patterns for metrics we need
    patterns = {
        'node_cpu_seconds_total{cpu="0",mode="idle"}': r'node_cpu_seconds_total\{cpu="0",mode="idle"\}\s+([\d.]+)',
        'node_memory_MemAvailable_bytes': r'node_memory_MemAvailable_bytes\s+([\d.]+)',
        'node_memory_MemTotal_bytes': r'node_memory_MemTotal_bytes\s+([\d.]+)',
        'node_filesystem_avail_bytes{mountpoint="/"}': r'node_filesystem_avail_bytes\{.*mountpoint="/".*\}\s+([\d.]+)',
        'node_filesystem_size_bytes{mountpoint="/"}': r'node_filesystem_size_bytes\{.*mountpoint="/".*\}\s+([\d.]+)',
        'node_network_receive_bytes_total{device="eth0"}': r'node_network_receive_bytes_total\{device="eth0"\}\s+([\d.]+)',
        'node_network_transmit_bytes_total{device="eth0"}': r'node_network_transmit_bytes_total\{device="eth0"\}\s+([\d.]+)',
        'node_load1': r'node_load1\s+([\d.]+)',
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, raw)
        if match:
            metrics[key] = float(match.group(1))
    return metrics

async def scrape_node(host: str, port: int = 9100, retries: int = 2) -> dict:
    """Scrape node_exporter metrics from a single host with retry logic."""
    url = f"http://{host}:{port}/metrics"
    
    for attempt in range(retries + 1):
        try:
            r = await http_client.get(url, timeout=SCRAPE_TIMEOUT)
            raw = _parse_node_exporter(r.text)
            cpu_idle = raw.get('node_cpu_seconds_total{cpu="0",mode="idle"}')
            mem_avail  = raw.get("node_memory_MemAvailable_bytes", 0)
            mem_total  = raw.get("node_memory_MemTotal_bytes", 1)
            disk_avail = raw.get('node_filesystem_avail_bytes{mountpoint="/"}', 0)
            disk_total = raw.get('node_filesystem_size_bytes{mountpoint="/"}', 1)
            net_rx     = raw.get('node_network_receive_bytes_total{device="eth0"}', 0)
            net_tx     = raw.get('node_network_transmit_bytes_total{device="eth0"}', 0)
            load1      = raw.get("node_load1", 0.0)

            return {
                "host": host,
                "status": "ok",
                "cpu_idle_pct": round(cpu_idle or 0, 1),
                "mem_used_pct": round((1 - mem_avail / mem_total) * 100, 1),
                "disk_used_pct": round((1 - disk_avail / disk_total) * 100, 1),
                "net_rx_bytes": int(net_rx),
                "net_tx_bytes": int(net_tx),
                "load1": round(load1, 2),
                "ts": time.time(),
            }
        except Exception as exc:
            if attempt < retries:
                await asyncio.sleep(0.5 * (2 ** attempt))  # Exponential backoff
                continue
            return {"host": host, "status": "unreachable", "error": str(exc), "ts": time.time()}
    
    return {"host": host, "status": "unreachable", "error": "Max retries exceeded", "ts": time.time()}

def load_inventory() -> list[dict]:
    """Parse a simple INI inventory and return host list with caching."""
    global inventory_cache, inventory_mtime
    
    if not os.path.exists(INVENTORY):
        return []
    
    # Check if file has been modified
    current_mtime = os.path.getmtime(INVENTORY)
    if inventory_cache and current_mtime == inventory_mtime:
        return inventory_cache
    
    hosts = []
    current_group = "ungrouped"
    with open(INVENTORY) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                current_group = line[1:-1]
                continue
            # Skip variable definitions
            if "=" in line and not line.split()[0].replace("-", "").replace("_", "").isalnum():
                continue
            # hostname or ip, optional vars
            parts = line.split()
            if not parts:
                continue
            host_entry = parts[0]
            # Skip if it looks like a variable assignment
            if "=" in host_entry and " " not in host_entry:
                continue
            ip = None
            for p in parts[1:]:
                if p.startswith("ansible_host="):
                    ip = p.split("=", 1)[1]
            hosts.append({
                "name": host_entry,
                "ip": ip or host_entry,
                "group": current_group,
                "type": "master" if "master" in current_group else "worker",
            })
    
    # Update cache
    inventory_cache = hosts
    inventory_mtime = current_mtime
    return hosts

# ── Background metrics push loop ─────────────────────────────────────────────

async def metrics_loop():
    """Scrape all nodes every SCRAPE_INTERVAL seconds and broadcast."""
    while True:
        inventory = load_inventory()
        if not inventory:
            await asyncio.sleep(SCRAPE_INTERVAL)
            continue

        tasks = [scrape_node(h["ip"]) for h in inventory]
        results = await asyncio.gather(*tasks)

        # Stitch inventory metadata into results
        ip_to_meta = {h["ip"]: h for h in inventory}
        enriched = []
        for r in results:
            meta = ip_to_meta.get(r["host"], {})
            enriched.append({**r, **meta})

        await manager.broadcast({"type": "metrics", "nodes": enriched, "ts": time.time()})
        await asyncio.sleep(SCRAPE_INTERVAL)

@app.on_event("startup")
async def startup():
    global http_client
    http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(SCRAPE_TIMEOUT),
        limits=httpx.Limits(max_keepalive_connections=20, max_connections=50)
    )
    asyncio.create_task(metrics_loop())

@app.on_event("shutdown")
async def shutdown():
    if http_client:
        await http_client.aclose()

# ── WebSocket endpoint ────────────────────────────────────────────────────────

@app.websocket("/ws/metrics")
async def ws_metrics(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            await websocket.receive_text()   # keep alive
    except WebSocketDisconnect:
        manager.disconnect(websocket)

# ── REST: inventory ───────────────────────────────────────────────────────────

@app.get("/api/inventory")
def get_inventory():
    return {"nodes": load_inventory()}

# ── REST: run playbook ────────────────────────────────────────────────────────

@app.post("/api/v1/playbook/run")
@limiter.limit("10/minute")
async def run_playbook(request: Request, req: PlaybookRequest):
    playbook_path = Path(ANSIBLE_DIR) / "playbooks" / req.playbook
    
    # Security: Verify path is within playbooks directory
    try:
        playbook_path = playbook_path.resolve()
        playbooks_dir = (Path(ANSIBLE_DIR) / "playbooks").resolve()
        if not str(playbook_path).startswith(str(playbooks_dir)):
            raise HTTPException(status_code=400, detail="Invalid playbook path")
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid playbook path")
    
    if not playbook_path.exists():
        raise HTTPException(status_code=404, detail=f"Playbook not found: {req.playbook}")

    cmd = [
        "ansible-playbook", str(playbook_path),
        "-i", INVENTORY,
        "--limit", req.limit,
    ]
    if req.extra_vars:
        cmd += ["--extra-vars", json.dumps(req.extra_vars)]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=ANSIBLE_DIR
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=PLAYBOOK_TIMEOUT
        )
        return {
            "rc": proc.returncode,
            "stdout": stdout.decode()[-8000:],
            "stderr": stderr.decode()[-2000:],
        }
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise HTTPException(status_code=504, detail=f"Playbook timed out ({PLAYBOOK_TIMEOUT}s)")

# ── REST: AI agent command ────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are an expert Ansible infrastructure automation agent.
You have access to a cluster of nodes managed by Ansible.
When a user gives you a command, you:
1. Analyze the intent and the current cluster state provided.
2. Decide which Ansible playbook or ad-hoc command to run.
3. Return a structured JSON response with:
   - "intent": one-sentence summary of what you understood
   - "action": "run_playbook" | "ad_hoc" | "query" | "explain"
   - "playbook": playbook filename if action=run_playbook
   - "limit": host pattern (default "all")
   - "message": human-readable explanation of what will happen
   - "commands": list of ansible commands to run (for display)
Always be precise, safe, and explain what you are about to do before doing it.
Respond ONLY with valid JSON, no markdown fences."""

# Maintain backward compatibility
@app.post("/api/playbook/run")
@limiter.limit("10/minute")
async def run_playbook_legacy(request: Request, req: PlaybookRequest):
    return await run_playbook(request, req)

@app.post("/api/v1/ai/run")
@limiter.limit("20/minute")
async def ai_run(request: Request, req: AICommandRequest):
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise HTTPException(status_code=500, detail="ANTHROPIC_API_KEY not set")

    context_str = json.dumps(req.context, indent=2) if req.context else "No context provided."

    try:
        r = await http_client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-sonnet-4-20250514",
                "max_tokens": 1024,
                "system": SYSTEM_PROMPT,
                "messages": [
                    {
                        "role": "user",
                        "content": f"Cluster state:\n{context_str}\n\nCommand: {req.prompt}",
                    }
                ],
            },
            timeout=AI_TIMEOUT,
        )
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="AI request timed out")

    if r.status_code != 200:
        raise HTTPException(status_code=r.status_code, detail=r.text)

    data = r.json()
    raw_text = data["content"][0]["text"]

    try:
        parsed = json.loads(raw_text)
    except json.JSONDecodeError:
        parsed = {"intent": req.prompt, "action": "explain", "message": raw_text}

    return {"result": parsed, "raw": raw_text}

# Maintain backward compatibility
@app.post("/api/ai/run")
@limiter.limit("20/minute")
async def ai_run_legacy(request: Request, req: AICommandRequest):
    return await ai_run(request, req)

# ── REST: ad-hoc command ──────────────────────────────────────────────────────

@app.post("/api/v1/adhoc")
@limiter.limit("15/minute")
async def adhoc(request: Request, req: AdHocRequest):
    cmd = ["ansible", req.limit, "-i", INVENTORY, "-m", req.module]
    if req.args:
        cmd += ["-a", req.args]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=ANSIBLE_DIR
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=ADHOC_TIMEOUT
        )
        return {
            "rc": proc.returncode,
            "stdout": stdout.decode(),
            "stderr": stderr.decode()
        }
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise HTTPException(status_code=504, detail=f"Ad-hoc command timed out ({ADHOC_TIMEOUT}s)")

# Maintain backward compatibility
@app.post("/api/adhoc")
@limiter.limit("15/minute")
async def adhoc_legacy(request: Request, body: dict):
    req = AdHocRequest(
        module=body.get("module", "ping"),
        args=body.get("args", ""),
        limit=body.get("limit", "all")
    )
    return await adhoc(request, req)

# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "ts": time.time()}
